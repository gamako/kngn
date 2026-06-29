// 基本ウィジェット（TASK-21.5）: Button / ColorSwatch。
// Label（label / labelEx）は Context 本体（context.zig）が提供する。
//
// 同期 hit-test 契約（21.2/21.4）:
//   widget 呼び出し時に「前フレームの rect キャッシュ」で buttonBehavior を行い、
//   ButtonResult を同期返却する。初回フレーム（キャッシュ未生成）は非ヒット扱い。
//   描画はレイアウトノードに記録され、endFrame の layout 確定後に発行される。
//   hover 色は state.hot_id（beginFrame で確定、フレーム中不変）を参照する。
//
// 自動 ID の重複に注意:
//   button は label hash + id_stack、colorSwatch は色値 hash + id_stack で ID を作る。
//   同一スコープに同ラベル / 同色を並べると明示 ID 重複となり endFrame の debug assert が
//   発火する。buttonId / colorSwatchId か id_stack.push(i) のスコープで回避すること。

const std = @import("std");

const context_mod = @import("context.zig");
const layout = @import("layout.zig");
const color_mod = @import("color.zig");
const draw_mod = @import("draw.zig");
const geom = @import("geom.zig");
const id_mod = @import("id.zig");
const input_mod = @import("input.zig");
pub const Vec2f = input_mod.Vec2f;

pub const Context = context_mod.Context;
pub const ButtonResult = context_mod.ButtonResult;
pub const Color = color_mod.Color;
pub const DrawList = draw_mod.DrawList;
pub const Rect = geom.Rect;
pub const Id = id_mod.Id;

pub const ButtonOpts = struct {
    /// 0 より大きければボタン幅の下限（text + padding がそれ未満でも min_w を確保）
    min_w: i32 = 0,
    /// null なら style.button_padding
    padding: ?[4]i32 = null,
    /// 選択中表示（太枠 = style.button_border_selected）。ツール選択のトグル表示用
    selected: bool = false,
};

pub const SwatchOpts = struct {
    color: Color,
    /// 選択中表示（太枠 = style.swatch_border_selected + 強調色）
    selected: bool = false,
    /// null なら style.swatch_size
    size: ?i32 = null,
};

/// i32 スライダー設定。事前条件: max > min、step は null か > 0。
pub const SliderI32Opts = struct {
    min: i32,
    max: i32,
    step: ?i32 = null,
    /// null なら style.slider_track_w
    track_w: ?i32 = null,
};

/// f32 スライダー設定。事前条件: max > min、step は null か > 0。
pub const SliderF32Opts = struct {
    min: f32,
    max: f32,
    step: ?f32 = null,
    track_w: ?i32 = null,
};

/// クリックされたら true（自動 ID: label hash + id_stack）。
pub fn button(ctx: *Context, label: []const u8) bool {
    return buttonEx(ctx, label, .{}).clicked;
}

/// ButtonResult（clicked / hovered / held）を返す版（自動 ID）。
pub fn buttonEx(ctx: *Context, label: []const u8, opts: ButtonOpts) ButtonResult {
    return buttonId(ctx, ctx.id_stack.make(label), label, opts);
}

/// 明示 ID 版。rect を getNodeRect(id) で外部参照する場合（pixie の Save ボタン等）や、
/// 同一スコープに同ラベルを並べる場合に使う。
pub fn buttonId(ctx: *Context, id: Id, label: []const u8, opts: ButtonOpts) ButtonResult {
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const hot = ctx.state.hot_id == id;
    const bg = if (result.held) style.bg_active else if (hot) style.bg_hover else style.bg;
    const border_color = if (hot) style.border_hover else style.border;
    const thickness = if (opts.selected) style.button_border_selected else style.button_border;
    const pad = opts.padding orelse style.button_padding;
    // min_w 指定時は固定幅フォント（measure = 8×len）前提で呼び出し時に幅を確定できる
    const width: layout.Sizing = if (opts.min_w > 0)
        .{ .fixed = @max(opts.min_w, @as(i32, @intCast(ctx.font.measure(label))) + pad[3] + pad[1]) }
    else
        .fit;
    ctx.beginBox(.{
        .id = id,
        .width = width,
        .padding = pad,
        .bg = bg,
        .border = makeBorder(border_color, thickness),
    });
    ctx.labelEx(label, style.text);
    ctx.endBox();
    return result;
}

/// クリックされたら true（自動 ID: 色値 hash + id_stack）。
pub fn colorSwatch(ctx: *Context, color: Color, selected: bool) bool {
    return colorSwatchEx(ctx, .{ .color = color, .selected = selected }).clicked;
}

/// ButtonResult を返す版（自動 ID）。
pub fn colorSwatchEx(ctx: *Context, opts: SwatchOpts) ButtonResult {
    return colorSwatchId(ctx, ctx.id_stack.makeInt(@as(u32, @bitCast(opts.color))), opts);
}

/// 明示 ID 版。パレットのように同色が並びうる場合はこちらを使う。
pub fn colorSwatchId(ctx: *Context, id: Id, opts: SwatchOpts) ButtonResult {
    const result = behaviorFromCache(ctx, id);
    const style = ctx.style;
    const size = opts.size orelse style.swatch_size;
    const border = if (opts.selected)
        makeBorder(style.border_hover, style.swatch_border_selected)
    else
        makeBorder(style.border, style.swatch_border);
    if (opts.color.a == 0xFF) {
        ctx.beginBox(.{
            .id = id,
            .width = .{ .fixed = size },
            .height = .{ .fixed = size },
            .bg = opts.color,
            .border = border,
        });
        ctx.endBox();
    } else {
        // 半透明: チェック柄の上に色を blend する。box の bg は子より先に描かれて
        // checker を覆えないため、checker + 色を custom leaf でまとめて描く。
        ctx.beginBox(.{
            .id = id,
            .width = .{ .fixed = size },
            .height = .{ .fixed = size },
            .border = border,
        });
        const data = ctx.allocator().create(SwatchDraw) catch @panic("colorSwatch: OOM");
        data.* = .{ .color = opts.color };
        ctx.custom(.{ .x = size, .y = size }, SwatchDraw.draw, data);
        ctx.endBox();
    }
    return result;
}

/// 前フレームの rect キャッシュで同期 hit-test。キャッシュ未生成（初回フレーム・
/// 前フレーム非表示）の widget は非ヒット扱い（21.2/21.4 契約）。
fn behaviorFromCache(ctx: *Context, id: Id) ButtonResult {
    const cached = ctx.rect_cache.get(id) orelse return .{};
    return context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
}

/// thickness <= 0 は「枠なし」（render の rectOutline は thickness 0 を 1 扱いするため、
/// ここで null に落とす）。
fn makeBorder(color: Color, thickness: i32) ?layout.Border {
    if (thickness <= 0) return null;
    return .{ .color = color, .thickness = @intCast(thickness) };
}

/// 半透明 swatch の描画データ。arena 上に確保され次 beginFrame まで生存
/// （draw_fn は endFrame 中に呼ばれるので寿命は十分）。
const SwatchDraw = struct {
    color: Color,

    const cell: i32 = 4;
    const light = Color.rgba(0xCC, 0xCC, 0xCC, 0xFF);
    const dark = Color.rgba(0x88, 0x88, 0x88, 0xFF);

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SwatchDraw = @ptrCast(@alignCast(ctx_ptr));
        const w: i32 = @intCast(rect.w);
        const h: i32 = @intCast(rect.h);
        // チェック柄（cell px 格子、(row+col) の偶奇で 2 色）
        var y: i32 = 0;
        var row: u32 = 0;
        while (y < h) : ({
            y += cell;
            row += 1;
        }) {
            var x: i32 = 0;
            var col: u32 = 0;
            while (x < w) : ({
                x += cell;
                col += 1;
            }) {
                const c = if ((row + col) % 2 == 0) light else dark;
                dl.rectFilled(.{
                    .x = rect.x + x,
                    .y = rect.y + y,
                    .w = @intCast(@min(cell, w - x)),
                    .h = @intCast(@min(cell, h - y)),
                }, c) catch @panic("colorSwatch: OOM");
            }
        }
        // 色を blend で重ねる（render の rect_filled は straight alpha src-over）
        dl.rectFilled(rect, self.color) catch @panic("colorSwatch: OOM");
    }
};

// ── Slider（TASK-21.9）─────────────────────────────────────
// track を明示 ID box で登録 → 各フレーム value から knob 矩形を算出 → knob 矩形で
// buttonBehavior を呼んで active を取得（press は knob 上のみ = track だけクリックでは飛ばない）。
// active 中は mouse_pos.x を track 可動域へ写像して *value を更新。内部計算は f64。
// レイアウトは [固定名ラベル] [track] [動的値テキスト] で、track の x は値の桁数に依存しない。

/// i32 スライダー（自動 ID: label hash）。値が変われば true。
pub fn sliderI32(ctx: *Context, label: []const u8, value: *i32, opts: SliderI32Opts) bool {
    return sliderI32Id(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// 明示 ID 版。
pub fn sliderI32Id(ctx: *Context, id: Id, label: []const u8, value: *i32, opts: SliderI32Opts) bool {
    const spec: SliderSpec = .{
        .min = @floatFromInt(opts.min),
        .max = @floatFromInt(opts.max),
        .step = if (opts.step) |s| @floatFromInt(s) else null,
        .track_w = opts.track_w orelse ctx.style.slider_track_w,
        .is_float = false,
    };
    const old = value.*;
    value.* = @intFromFloat(@round(sliderCore(ctx, id, label, @floatFromInt(old), spec)));
    return value.* != old;
}

/// f32 スライダー（自動 ID: label hash）。値が変われば true。
pub fn sliderF32(ctx: *Context, label: []const u8, value: *f32, opts: SliderF32Opts) bool {
    return sliderF32Id(ctx, ctx.id_stack.make(label), label, value, opts);
}

/// 明示 ID 版。
pub fn sliderF32Id(ctx: *Context, id: Id, label: []const u8, value: *f32, opts: SliderF32Opts) bool {
    const spec: SliderSpec = .{
        .min = opts.min,
        .max = opts.max,
        .step = if (opts.step) |s| @as(f64, s) else null,
        .track_w = opts.track_w orelse ctx.style.slider_track_w,
        .is_float = true,
    };
    const old = value.*;
    value.* = @floatCast(sliderCore(ctx, id, label, old, spec));
    return value.* != old;
}

const SliderSpec = struct {
    min: f64,
    max: f64,
    step: ?f64,
    track_w: i32,
    is_float: bool,
};

/// knob 中心が動ける範囲 [lo, lo+span]（px、f64）。track の左右に knob_w/2 のマージン。
const KnobRange = struct { lo: f64, span: f64 };
fn knobRange(track: Rect, knob_w: i32) KnobRange {
    const lo: f64 = @floatFromInt(track.x + @divTrunc(knob_w, 2));
    const raw: f64 = @floatFromInt(@as(i32, @intCast(track.w)) - knob_w);
    return .{ .lo = lo, .span = if (raw < 1) 1 else raw };
}

fn knobRectFor(track: Rect, knob_w: i32, knob_h: i32, frac: f64) Rect {
    const range = knobRange(track, knob_w);
    const cx: i32 = @intFromFloat(range.lo + frac * range.span);
    const ty: i32 = track.y + @divTrunc(@as(i32, @intCast(track.h)) - knob_h, 2);
    return .{
        .x = cx - @divTrunc(knob_w, 2),
        .y = ty,
        .w = @intCast(knob_w),
        .h = @intCast(knob_h),
    };
}

fn clampAndStep(v: f64, spec: SliderSpec) f64 {
    var x = std.math.clamp(v, spec.min, spec.max);
    if (spec.step) |s| {
        x = spec.min + @round((x - spec.min) / s) * s;
        x = std.math.clamp(x, spec.min, spec.max);
    }
    return x;
}

/// 最終値（f64）を返す。読み取り時は clamp のみ（step スナップしない＝drift 回避）。
/// step はドラッグ更新時のみ適用する。changed 判定は呼び出し側が「最終値 ≠ 旧値」で行う。
fn sliderCore(ctx: *Context, id: Id, label: []const u8, cur: f64, spec: SliderSpec) f64 {
    std.debug.assert(spec.max > spec.min);
    if (spec.step) |s| std.debug.assert(s > 0);
    const style = ctx.style;
    const knob_w = style.slider_knob_w;
    const knob_h = style.slider_knob_h;

    // 表示/hit-test 用に範囲内へ clamp（clamp は exact なので毎フレーム呼んでも drift しない）。
    var value = std.math.clamp(cur, spec.min, spec.max);

    // hit-test / drag（前フレーム track rect の knob 矩形で active 取得）
    if (ctx.rect_cache.get(id)) |cached| {
        const track = cached.rect;
        const range = knobRange(track, knob_w);
        const frac = (value - spec.min) / (spec.max - spec.min);
        const kr = knobRectFor(track, knob_w, knob_h, frac);
        const res = context_mod.buttonBehavior(ctx, id, kr, cached.clip);
        if (res.held) {
            const mx: f64 = @floatFromInt(ctx.input.mouse_pos.x);
            const t = std.math.clamp((mx - range.lo) / range.span, 0, 1);
            value = clampAndStep(spec.min + t * (spec.max - spec.min), spec); // ドラッグ時のみ step 適用
        }
    }

    // 構築/描画: [label] [track(id)] [value text]
    ctx.beginBox(.{ .direction = .row, .gap = 6, .align_cross = .center });
    ctx.label(label);

    const data = ctx.allocator().create(SliderDraw) catch @panic("slider: OOM");
    data.* = .{
        .frac = (value - spec.min) / (spec.max - spec.min),
        .knob_w = knob_w,
        .knob_h = knob_h,
        .track_h = style.slider_track_h,
        .track_bg = style.slider_track_bg,
        .knob_bg = if (ctx.state.active_id == id) style.slider_knob_active_bg else style.slider_knob_bg,
        .border = style.border,
    };
    ctx.beginBox(.{
        .id = id,
        .width = .{ .fixed = spec.track_w },
        .height = .{ .fixed = knob_h },
    });
    ctx.custom(.{ .x = spec.track_w, .y = knob_h }, SliderDraw.draw, data);
    ctx.endBox();

    var buf: [32]u8 = undefined;
    const txt = if (spec.is_float)
        std.fmt.bufPrint(&buf, "{d:.2}", .{value}) catch "?"
    else
        std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(@round(value)))}) catch "?";
    ctx.label(txt); // labelEx が arena へ dupe するので stack buf で安全

    ctx.endBox();

    return value;
}

/// slider の track 帯 + knob を描く custom leaf データ（arena 上、endFrame 中に draw 呼出）。
const SliderDraw = struct {
    frac: f64,
    knob_w: i32,
    knob_h: i32,
    track_h: i32,
    track_bg: Color,
    knob_bg: Color,
    border: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SliderDraw = @ptrCast(@alignCast(ctx_ptr));
        // track 帯（縦中央・高さ track_h）
        const track_y: i32 = rect.y + @divTrunc(@as(i32, @intCast(rect.h)) - self.track_h, 2);
        dl.rectFilled(
            .{ .x = rect.x, .y = track_y, .w = rect.w, .h = @intCast(self.track_h) },
            self.track_bg,
        ) catch @panic("slider: OOM");
        // knob（rect = 最終 layout 後の track 外接矩形。hit-test と同じ knobRectFor で位置一致）
        const kr = knobRectFor(rect, self.knob_w, self.knob_h, self.frac);
        dl.rectFilled(kr, self.knob_bg) catch @panic("slider: OOM");
        dl.rectOutline(kr, self.border, 1) catch @panic("slider: OOM");
    }
};

// ── HSV カラーピッカー（TASK-21.14）─────────────────────────
// 既存 DrawCmd.image を再利用してグラデを描く。グラデバッファは widget 呼び出し時に arena へ
// 確保し custom leaf で dl.image する（render まで生存）。固定 px（dl.image は rect.w==src_w を
// assert するため grow/stretch 不可）。前フレーム rect_cache 契約は Slider と同じ。

pub const SvSquareOpts = struct {
    /// null なら style.picker_sv_size。最小 2。
    size: ?i32 = null,
};

pub const HueBarOpts = struct {
    /// null なら style.picker_hue_w / picker_sv_size。w>=1, h>=2。
    w: ?i32 = null,
    h: ?i32 = null,
};

/// SV スクエア（自動 ID: label hash）。指定 hue で saturation(x)/value(y) を編集。値が変われば true。
pub fn svSquare(ctx: *Context, label: []const u8, hue: f32, s: *f32, v: *f32, opts: SvSquareOpts) bool {
    return svSquareId(ctx, ctx.id_stack.make(label), hue, s, v, opts);
}

/// 明示 ID 版。
pub fn svSquareId(ctx: *Context, id: Id, hue: f32, s: *f32, v: *f32, opts: SvSquareOpts) bool {
    const size = opts.size orelse ctx.style.picker_sv_size;
    std.debug.assert(size >= 2);
    const old_s = s.*;
    const old_v = v.*;
    // 表示/hit-test 用に [0,1] clamp（clamp は exact なので drift しない）
    s.* = std.math.clamp(s.*, 0, 1);
    v.* = std.math.clamp(v.*, 0, 1);

    // hit-test / drag（square 全体が drag 領域。Slider の knob 限定とは異なり「面」を掴む）
    if (ctx.rect_cache.get(id)) |cached| {
        const r = cached.rect;
        const res = context_mod.buttonBehavior(ctx, id, r, cached.clip);
        if (res.held) {
            const w1: f32 = @floatFromInt(@as(i32, @intCast(r.w)) - 1);
            const h1: f32 = @floatFromInt(@as(i32, @intCast(r.h)) - 1);
            const mx: f32 = @floatFromInt(ctx.input.mouse_pos.x - r.x);
            const my: f32 = @floatFromInt(ctx.input.mouse_pos.y - r.y);
            s.* = std.math.clamp(mx / w1, 0, 1);
            v.* = std.math.clamp(1 - my / h1, 0, 1); // 上=明
        }
    }

    // グラデバッファ（arena, [size*size]u32）
    const usz: usize = @intCast(size);
    const buf = ctx.allocator().alloc(u32, usz * usz) catch @panic("svSquare: OOM");
    const denom: f32 = @floatFromInt(size - 1);
    var py: usize = 0;
    while (py < usz) : (py += 1) {
        const vy = 1 - @as(f32, @floatFromInt(py)) / denom;
        var px: usize = 0;
        while (px < usz) : (px += 1) {
            const sx = @as(f32, @floatFromInt(px)) / denom;
            buf[py * usz + px] = @bitCast(Color.fromHsv(hue, sx, vy));
        }
    }
    const data = ctx.allocator().create(SvSquareDraw) catch @panic("svSquare: OOM");
    data.* = .{
        .buf = buf,
        .size = size,
        .s = s.*,
        .v = v.*,
        .marker_light = ctx.style.picker_marker_light,
        .marker_dark = ctx.style.picker_marker_dark,
    };
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = size }, .height = .{ .fixed = size } });
    ctx.custom(.{ .x = size, .y = size }, SvSquareDraw.draw, data);
    ctx.endBox();

    return s.* != old_s or v.* != old_v;
}

const SvSquareDraw = struct {
    buf: []const u32,
    size: i32,
    s: f32,
    v: f32,
    marker_light: Color,
    marker_dark: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const SvSquareDraw = @ptrCast(@alignCast(ctx_ptr));
        const w: u32 = @intCast(self.size);
        dl.image(rect, self.buf, w, w) catch @panic("svSquare: OOM");
        // マーカー: (s,v) 位置に明/暗 2 重枠（背景色に依らず視認）
        const w1: f32 = @floatFromInt(self.size - 1);
        const mx: i32 = rect.x + @as(i32, @intFromFloat(@round(self.s * w1)));
        const my: i32 = rect.y + @as(i32, @intFromFloat(@round((1 - self.v) * w1)));
        const half: i32 = 3;
        const outer: Rect = .{ .x = mx - half, .y = my - half, .w = @intCast(2 * half + 1), .h = @intCast(2 * half + 1) };
        dl.rectOutline(outer, self.marker_dark, 1) catch @panic("svSquare: OOM");
        const inner: Rect = .{ .x = outer.x + 1, .y = outer.y + 1, .w = outer.w - 2, .h = outer.h - 2 };
        dl.rectOutline(inner, self.marker_light, 1) catch @panic("svSquare: OOM");
    }
};

/// Hue バー（自動 ID: label hash）。縦方向に hue を編集。hue は常に [0,360)。値が変われば true。
pub fn hueBar(ctx: *Context, label: []const u8, h: *f32, opts: HueBarOpts) bool {
    return hueBarId(ctx, ctx.id_stack.make(label), h, opts);
}

/// 明示 ID 版。
pub fn hueBarId(ctx: *Context, id: Id, h: *f32, opts: HueBarOpts) bool {
    const bw = opts.w orelse ctx.style.picker_hue_w;
    const bh = opts.h orelse ctx.style.picker_sv_size;
    std.debug.assert(bw >= 1 and bh >= 2);
    const old = h.*;
    h.* = std.math.clamp(h.*, 0, 360 - 1e-3); // [0,360)

    if (ctx.rect_cache.get(id)) |cached| {
        const r = cached.rect;
        const res = context_mod.buttonBehavior(ctx, id, r, cached.clip);
        if (res.held) {
            const hh: f32 = @floatFromInt(r.h);
            const my: f32 = @floatFromInt(ctx.input.mouse_pos.y - r.y);
            const t = std.math.clamp(my / hh, 0, 1);
            h.* = @min(t * 360, 360 - 1e-3);
        }
    }

    const uw: usize = @intCast(bw);
    const uh: usize = @intCast(bh);
    const buf = ctx.allocator().alloc(u32, uw * uh) catch @panic("hueBar: OOM");
    const fbh: f32 = @floatFromInt(bh);
    var py: usize = 0;
    while (py < uh) : (py += 1) {
        const hue = (@as(f32, @floatFromInt(py)) / fbh) * 360; // /bh で 360 を出さない
        const col: u32 = @bitCast(Color.fromHsv(hue, 1, 1));
        var px: usize = 0;
        while (px < uw) : (px += 1) buf[py * uw + px] = col;
    }
    const data = ctx.allocator().create(HueBarDraw) catch @panic("hueBar: OOM");
    data.* = .{
        .buf = buf,
        .w = bw,
        .h = bh,
        .hue = h.*,
        .marker_light = ctx.style.picker_marker_light,
        .marker_dark = ctx.style.picker_marker_dark,
    };
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = bw }, .height = .{ .fixed = bh } });
    ctx.custom(.{ .x = bw, .y = bh }, HueBarDraw.draw, data);
    ctx.endBox();

    return h.* != old;
}

const HueBarDraw = struct {
    buf: []const u32,
    w: i32,
    h: i32,
    hue: f32,
    marker_light: Color,
    marker_dark: Color,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const HueBarDraw = @ptrCast(@alignCast(ctx_ptr));
        dl.image(rect, self.buf, @intCast(self.w), @intCast(self.h)) catch @panic("hueBar: OOM");
        // マーカー（横帯）: row = clamp(floor(hue/360*h), 0, h-1)（fill の /h 規約と一致）
        const fbh: f32 = @floatFromInt(self.h);
        const rowf = @floor(self.hue / 360.0 * fbh);
        const row: i32 = std.math.clamp(@as(i32, @intFromFloat(rowf)), 0, self.h - 1);
        const my = rect.y + row;
        dl.rectFilled(.{ .x = rect.x, .y = my - 1, .w = rect.w, .h = 3 }, self.marker_dark) catch @panic("hueBar: OOM");
        dl.rectFilled(.{ .x = rect.x, .y = my, .w = rect.w, .h = 1 }, self.marker_light) catch @panic("hueBar: OOM");
    }
};

// ── 画像ボックス（汎用・等倍 leaf。TASK-43）──────────────────
// svSquare / hueBar と同じく DrawCmd.image を使う固定 px leaf。pixels は caller 所有で
// render まで生存すること（frame arena 推奨）。dl.image が rect.w==src_w を assert するため
// 縮小は呼び出し側で行い、ここでは等倍 blit のみ。非対話（hit-test しない）。

pub const ImageBoxOpts = struct {
    /// 枠線色（null なら枠なし）
    border: ?Color = null,
    border_thickness: u32 = 1,
};

/// 等倍画像ボックス（明示 ID）。w×h の pixels を同サイズ rect へ blit する。
/// pixels.len == w*h、w>=1、h>=1。
pub fn imageBox(ctx: *Context, id: Id, pixels: []const u32, w: i32, h: i32, opts: ImageBoxOpts) void {
    std.debug.assert(w >= 1 and h >= 1);
    std.debug.assert(pixels.len == @as(usize, @intCast(w)) * @as(usize, @intCast(h)));
    const data = ctx.allocator().create(ImageBoxDraw) catch @panic("imageBox: OOM");
    data.* = .{ .buf = pixels, .w = w, .h = h, .border = opts.border, .border_thickness = opts.border_thickness };
    ctx.beginBox(.{ .id = id, .width = .{ .fixed = w }, .height = .{ .fixed = h } });
    ctx.custom(.{ .x = w, .y = h }, ImageBoxDraw.draw, data);
    ctx.endBox();
}

const ImageBoxDraw = struct {
    buf: []const u32,
    w: i32,
    h: i32,
    border: ?Color,
    border_thickness: u32,

    fn draw(ctx_ptr: *anyopaque, dl: *DrawList, rect: Rect) void {
        const self: *const ImageBoxDraw = @ptrCast(@alignCast(ctx_ptr));
        dl.image(rect, self.buf, @intCast(self.w), @intCast(self.h)) catch @panic("imageBox: OOM");
        if (self.border) |c| dl.rectOutline(rect, c, self.border_thickness) catch @panic("imageBox: OOM");
    }
};

// ============================================================
// Splitter（ペイン境界ドラッグ。TASK-41）
// ============================================================

pub const Orient = enum { vertical, horizontal };

pub const SplitterOpts = struct {
    /// 境界帯の太さ（主軸 px）
    thickness: i32 = 6,
    min: i32 = 0,
    max: i32 = std.math.maxInt(i32),
    /// pane が splitter の右/下にある場合 true: マウス正方向（右/下）ドラッグで pane size は「減る」ので
    /// delta を反転する（`size += if (invert) -delta else delta`）。左/上 pane は false。
    invert: bool = false,
};

/// orient 軸の生 delta（mouse_delta の該当成分）に invert を適用した符号付き delta。
fn splitterDelta(orient: Orient, mouse_dx: i32, mouse_dy: i32, invert: bool) i32 {
    const d = if (orient == .vertical) mouse_dx else mouse_dy;
    return if (invert) -d else d;
}

/// 境界帯をドラッグして size を増減する（変化したら true）。
/// 同期 hit-test 契約: 前フレーム rect で buttonBehavior、held 中に mouse_delta を size へ反映し min/max clamp。
/// vertical=幅 thickness・高さ grow / horizontal=高さ thickness・幅 grow の明示 id box として配置する。
pub fn splitter(ctx: *Context, id: Id, orient: Orient, size: *i32, opts: SplitterOpts) bool {
    std.debug.assert(opts.thickness > 0);
    const old = size.*;

    // hit-test / drag（前フレーム rect の帯矩形で active 取得）
    if (ctx.rect_cache.get(id)) |cached| {
        const res = context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip);
        if (res.held) {
            const delta = splitterDelta(orient, ctx.input.mouse_delta.x, ctx.input.mouse_delta.y, opts.invert);
            size.* = std.math.clamp(size.* + delta, opts.min, opts.max);
        }
    }

    // 帯を明示 id box として配置。色は安定 hot_id/active_id（フレーム中不変）で選ぶ。
    const style = ctx.style;
    const col = if (ctx.state.active_id == id)
        style.bg_active
    else if (ctx.state.hot_id == id)
        style.border_hover
    else
        style.border;
    switch (orient) {
        .vertical => ctx.beginBox(.{ .id = id, .width = .{ .fixed = opts.thickness }, .height = .{ .grow = 1 }, .bg = col }),
        .horizontal => ctx.beginBox(.{ .id = id, .width = .{ .grow = 1 }, .height = .{ .fixed = opts.thickness }, .bg = col }),
    }
    ctx.endBox();

    return size.* != old;
}

// ============================================================
// ScrollArea（縦横スクロール領域 + スクロールバー。TASK-46）
// ============================================================
// 構造: outer(row) → [ leftCol(column) → [ viewport(clip,scroll) → content(fit) , hbar ] , vbar ]
// viewport は前フレーム rect、content は前フレーム measured（自然サイズ）を rect_cache から参照し、
// scroll 量の clamp・bar 表示要否・thumb 幾何を **前フレーム値**で決める（splitter と同じ同期契約。
// content サイズや viewport サイズが変わったフレームは 1 フレームだけ過渡値になり、次フレームで自己補正）。
// scroll 値は呼び出し側が *Vec2f で保持（trackpad の小数を保つ）。layout へは round した i32 を渡す。

const SCROLL_MIN_THUMB: i32 = 16;

pub const ScrollAreaOpts = struct {
    /// outer（スクロール領域全体）の主軸/交差軸サイズ
    width: layout.Sizing = .{ .grow = 1 },
    height: layout.Sizing = .{ .grow = 1 },
    /// inner content の方向・padding・gap・交差整列（caller の中身に効く）
    direction: layout.Direction = .column,
    padding: [4]i32 = .{ 0, 0, 0, 0 },
    gap: i32 = 0,
    align_cross: layout.Align = .start,
    /// inner content のサイズ規則。既定 .fit（自然サイズ＝両軸スクロール可能）。
    /// 横スクロール不要で content を viewport 幅いっぱいにしたい場合は content_width = .{ .grow = 1 }。
    content_width: layout.Sizing = .fit,
    content_height: layout.Sizing = .fit,
    /// outer の背景・枠
    bg: ?Color = null,
    border: ?layout.Border = null,
    /// ホイール 1 ノッチあたりの px
    wheel_px: f32 = 32.0,
    /// スクロールバー帯の厚み（px）
    bar_thickness: i32 = 8,
};

fn scrollThumbLen(viewport_len: i32, content_len: i32) i32 {
    if (content_len <= 0 or viewport_len <= 0) return @max(0, viewport_len);
    // 下限は viewport 長を超えない（小さい viewport で clamp の min>max assert を避ける）。
    const min_thumb = @min(SCROLL_MIN_THUMB, viewport_len);
    // i64 で乗算して大きい viewport での i32 overflow を避ける。
    const raw: i32 = @intCast(@divTrunc(@as(i64, viewport_len) * @as(i64, viewport_len), @as(i64, content_len)));
    return std.math.clamp(raw, min_thumb, viewport_len);
}

fn scrollThumbColor(ctx: *Context, st: context_mod.ScrollState, thumb_id: Id) Color {
    return if (ctx.state.active_id == thumb_id)
        st.thumb_active
    else if (ctx.state.hot_id == thumb_id)
        st.thumb_hot
    else
        st.thumb_col;
}

/// 縦横スクロール領域を開始する。`id` は viewport の明示 ID（getNodeRect(id)=viewport 矩形）。
/// `scroll` は呼び出し側保持の f32 スクロール量（x/y）。begin 後に中身の widget を積み、endScrollArea で閉じる。
pub fn beginScrollArea(ctx: *Context, id: Id, scroll: *Vec2f, opts: ScrollAreaOpts) void {
    const content_id = id_mod.hashInt(id, 1);
    const vthumb_id = id_mod.hashInt(id, 2);
    const hthumb_id = id_mod.hashInt(id, 3);

    // 前フレーム viewport rect / content 自然サイズ
    const vp = ctx.getNodeRect(id);
    const cm = ctx.getNodeMeasured(content_id);
    const vp_w: i32 = if (vp) |r| @intCast(r.w) else 0;
    const vp_h: i32 = if (vp) |r| @intCast(r.h) else 0;
    const content_w: i32 = if (cm) |m| m.x else 0;
    const content_h: i32 = if (cm) |m| m.y else 0;
    const max_x: i32 = @max(0, content_w - vp_w);
    const max_y: i32 = @max(0, content_h - vp_h);
    const need_v = max_y > 0;
    const need_h = max_x > 0;

    // ホイール: mouse が前フレーム viewport 内のときだけ反映（canvas zoom 等との領域分離）
    if (vp) |r| {
        const mp = ctx.input.mouse_pos;
        const inside = mp.x >= r.x and mp.x < r.x + @as(i32, @intCast(r.w)) and
            mp.y >= r.y and mp.y < r.y + @as(i32, @intCast(r.h));
        if (inside) {
            scroll.x += -ctx.input.scroll_delta.x * opts.wheel_px;
            scroll.y += -ctx.input.scroll_delta.y * opts.wheel_px;
        }
    }

    // thumb ドラッグ（前フレーム thumb rect で buttonBehavior、held 中 mouse_delta を scroll へ写像）
    if (need_v) {
        if (ctx.rect_cache.get(vthumb_id)) |c| {
            const res = context_mod.buttonBehavior(ctx, vthumb_id, c.rect, c.clip);
            if (res.held) {
                const travel = @max(1, vp_h - scrollThumbLen(vp_h, content_h));
                scroll.y += @as(f32, @floatFromInt(ctx.input.mouse_delta.y)) *
                    @as(f32, @floatFromInt(max_y)) / @as(f32, @floatFromInt(travel));
            }
        }
    }
    if (need_h) {
        if (ctx.rect_cache.get(hthumb_id)) |c| {
            const res = context_mod.buttonBehavior(ctx, hthumb_id, c.rect, c.clip);
            if (res.held) {
                const travel = @max(1, vp_w - scrollThumbLen(vp_w, content_w));
                scroll.x += @as(f32, @floatFromInt(ctx.input.mouse_delta.x)) *
                    @as(f32, @floatFromInt(max_x)) / @as(f32, @floatFromInt(travel));
            }
        }
    }

    // f32 のまま clamp
    scroll.x = std.math.clamp(scroll.x, 0, @as(f32, @floatFromInt(max_x)));
    scroll.y = std.math.clamp(scroll.y, 0, @as(f32, @floatFromInt(max_y)));

    // thumb 幾何（px）を clamp 済み scroll から算出
    var st: context_mod.ScrollState = .{
        .bar_thickness = opts.bar_thickness,
        .track_col = ctx.style.slider_track_bg,
        .thumb_col = ctx.style.border_hover,
        .thumb_hot = ctx.style.text_subtle,
        .thumb_active = ctx.style.bg_active,
        .need_v = need_v,
        .need_h = need_h,
        .v_off = 0,
        .v_len = 0,
        .h_off = 0,
        .h_len = 0,
        .vthumb_id = vthumb_id,
        .hthumb_id = hthumb_id,
    };
    if (need_v) {
        st.v_len = scrollThumbLen(vp_h, content_h);
        const travel = vp_h - st.v_len;
        st.v_off = if (max_y > 0)
            @intFromFloat(@round(scroll.y / @as(f32, @floatFromInt(max_y)) * @as(f32, @floatFromInt(travel))))
        else
            0;
    }
    if (need_h) {
        st.h_len = scrollThumbLen(vp_w, content_w);
        const travel = vp_w - st.h_len;
        st.h_off = if (max_x > 0)
            @intFromFloat(@round(scroll.x / @as(f32, @floatFromInt(max_x)) * @as(f32, @floatFromInt(travel))))
        else
            0;
    }
    ctx.scroll_stack.append(ctx.gpa, st) catch @panic("beginScrollArea: OOM");

    const sx: i32 = @intFromFloat(@round(scroll.x));
    const sy: i32 = @intFromFloat(@round(scroll.y));

    // outer(row) → leftCol(column) → viewport(clip,scroll) → inner content(fit)
    ctx.beginBox(.{ .direction = .row, .width = opts.width, .height = opts.height, .bg = opts.bg, .border = opts.border });
    ctx.beginBox(.{ .direction = .column, .width = .{ .grow = 1 }, .height = .{ .grow = 1 } });
    ctx.beginBox(.{ .id = id, .direction = opts.direction, .width = .{ .grow = 1 }, .height = .{ .grow = 1 }, .clip_children = true, .scroll_x = sx, .scroll_y = sy });
    ctx.beginBox(.{ .id = content_id, .direction = opts.direction, .width = opts.content_width, .height = opts.content_height, .padding = opts.padding, .gap = opts.gap, .align_cross = opts.align_cross });
}

/// scroll area を閉じてスクロールバーを構築する（begin と対で呼ぶ）。
pub fn endScrollArea(ctx: *Context) void {
    const st = ctx.scroll_stack.pop() orelse @panic("endScrollArea: begin と不対応");
    ctx.endBox(); // inner content
    ctx.endBox(); // viewport

    // 横スクロールバー（leftCol 内・viewport の下）
    if (st.need_h) {
        ctx.beginBox(.{ .direction = .row, .width = .{ .grow = 1 }, .height = .{ .fixed = st.bar_thickness }, .bg = st.track_col });
        if (st.h_off > 0) {
            ctx.beginBox(.{ .width = .{ .fixed = st.h_off }, .height = .{ .grow = 1 } });
            ctx.endBox();
        }
        ctx.beginBox(.{ .id = st.hthumb_id, .width = .{ .fixed = st.h_len }, .height = .{ .grow = 1 }, .bg = scrollThumbColor(ctx, st, st.hthumb_id) });
        ctx.endBox();
        ctx.endBox(); // hbar
    }
    ctx.endBox(); // leftCol

    // 縦スクロールバー（outer 内・leftCol の右）
    if (st.need_v) {
        ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = st.bar_thickness }, .height = .{ .grow = 1 }, .bg = st.track_col });
        if (st.v_off > 0) {
            ctx.beginBox(.{ .width = .{ .grow = 1 }, .height = .{ .fixed = st.v_off } });
            ctx.endBox();
        }
        ctx.beginBox(.{ .id = st.vthumb_id, .width = .{ .grow = 1 }, .height = .{ .fixed = st.v_len }, .bg = scrollThumbColor(ctx, st, st.vthumb_id) });
        ctx.endBox();
        ctx.endBox(); // vbar
    }
    ctx.endBox(); // outer
}

// ============================================================
// Tests
// ============================================================

const font_mod = @import("font.zig");
const render_mod = @import("render.zig");

fn testCtx() Context {
    return Context.init(std.testing.allocator, font_mod.default_font);
}

fn moveTo(ctx: *Context, x: i32, y: i32) void {
    ctx.pushEvent(.{ .mouse_move = .{ .x = x, .y = y, .modifiers = 0 } });
}

fn pressAt(ctx: *Context, x: i32, y: i32) void {
    moveTo(ctx, x, y);
    ctx.pushEvent(.{ .mouse_down = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn clickAt(ctx: *Context, x: i32, y: i32) void {
    pressAt(ctx, x, y);
    ctx.pushEvent(.{ .mouse_up = .{ .x = x, .y = y, .button = 0, .modifiers = 0 } });
}

fn center(rect: Rect) struct { x: i32, y: i32 } {
    return .{
        .x = rect.x + @as(i32, @intCast(rect.w / 2)),
        .y = rect.y + @as(i32, @intCast(rect.h / 2)),
    };
}

test "button: clicked は release フレームのみ true（1 フレーム edge / AC#2）" {
    var ctx = testCtx();
    defer ctx.deinit();

    // フレーム1: キャッシュ未生成 → 非ヒット（契約どおり）
    ctx.beginFrame(800, 600);
    try std.testing.expect(!ctx.button("Btn"));
    ctx.endFrame();
    const rect = ctx.getNodeRect(ctx.id_stack.make("Btn")).?;
    const c = center(rect);

    // フレーム2: press → held（まだ clicked ではない）
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    var res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(res.held);
    try std.testing.expect(!res.clicked);
    ctx.endFrame();

    // フレーム3: release → clicked
    ctx.beginFrame(800, 600);
    ctx.pushEvent(.{ .mouse_up = .{ .x = c.x, .y = c.y, .button = 0, .modifiers = 0 } });
    res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(res.clicked);
    ctx.endFrame();

    // フレーム4: 入力なし → false に戻る（edge）
    ctx.beginFrame(800, 600);
    res = ctx.buttonEx("Btn", .{});
    try std.testing.expect(!res.clicked);
    ctx.endFrame();
}

test "button: 同一フレーム press+release でも clicked（21.2 仕様の継承）" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    _ = ctx.button("Btn");
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ctx.id_stack.make("Btn")).?);

    ctx.beginFrame(800, 600);
    clickAt(&ctx, c.x, c.y);
    try std.testing.expect(ctx.button("Btn"));
    ctx.endFrame();
}

test "splitterDelta: orient 軸選択と invert 符号" {
    try std.testing.expectEqual(@as(i32, 30), splitterDelta(.vertical, 30, 5, false)); // vertical は x
    try std.testing.expectEqual(@as(i32, -30), splitterDelta(.vertical, 30, 5, true)); // invert で反転
    try std.testing.expectEqual(@as(i32, 7), splitterDelta(.horizontal, 30, 7, false)); // horizontal は y
    try std.testing.expectEqual(@as(i32, -7), splitterDelta(.horizontal, 30, 7, true));
}

test "splitter: vertical drag が size を delta 分動かし max で clamp する" {
    var ctx = testCtx();
    defer ctx.deinit();
    var size: i32 = 200;
    const ID: Id = 0x5117e1;
    const opts: SplitterOpts = .{ .min = 100, .max = 400, .thickness = 6 };

    // frame1: 登録（rect cache 生成）
    ctx.beginFrame(800, 600);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    // frame2: press（active 取得。press までの移動 delta は size に影響しうるので値は assert しない）
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();

    // frame3: +30 ドラッグ（mouse_delta.x = 30、invert=false）→ size += 30
    const before = size;
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x + 30, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(before + 30, size);

    // frame4: 大きく + ドラッグ → max=400 で clamp
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x + 1000, c.y);
    _ = ctx.splitter(ID, .vertical, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(@as(i32, 400), size);
}

test "splitter: horizontal + invert で逆方向に動く" {
    var ctx = testCtx();
    defer ctx.deinit();
    var size: i32 = 200;
    const ID: Id = 0x5117e2;
    const opts: SplitterOpts = .{ .min = 100, .max = 400, .thickness = 6, .invert = true };

    ctx.beginFrame(800, 600);
    _ = ctx.splitter(ID, .horizontal, &size, opts);
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ID).?);

    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    _ = ctx.splitter(ID, .horizontal, &size, opts);
    ctx.endFrame();

    // +30 を y 方向にドラッグ → invert で size -= 30
    const before = size;
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y + 30);
    _ = ctx.splitter(ID, .horizontal, &size, opts);
    ctx.endFrame();
    try std.testing.expectEqual(before - 30, size);
}

fn buildPalette(ctx: *Context, results: *[16]ButtonResult) void {
    ctx.beginBox(.{ .direction = .column, .gap = 2 });
    var i: u64 = 0;
    while (i < 16) {
        ctx.beginBox(.{ .direction = .row, .gap = 2 });
        var col: u32 = 0;
        while (col < 4) : (col += 1) {
            results[@intCast(i)] = ctx.colorSwatchId(100 + i, .{
                .color = Color.rgba(@intCast(i * 10), 0x40, 0x40, 0xFF),
            });
            i += 1;
        }
        ctx.endBox();
    }
    ctx.endBox();
}

test "colorSwatch: 16 マスが独立に click できる（AC#3）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var results: [16]ButtonResult = undefined;

    // フレーム1: キャッシュ生成
    ctx.beginFrame(800, 600);
    buildPalette(&ctx, &results);
    ctx.endFrame();

    var target: u64 = 0;
    while (target < 16) : (target += 1) {
        const c = center(ctx.getNodeRect(100 + target).?);
        ctx.beginFrame(800, 600);
        clickAt(&ctx, c.x, c.y);
        buildPalette(&ctx, &results);
        ctx.endFrame();
        for (results, 0..) |r, j| {
            try std.testing.expectEqual(j == target, r.clicked);
        }
    }
}

test "colorSwatch: 同色でも id_stack.push スコープで独立（自動 ID）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const same = Color.rgba(0xD0, 0x46, 0x48, 0xFF);
    var res: [2]bool = undefined;

    const build = struct {
        fn f(c: *Context, color: Color, out: *[2]bool) void {
            c.beginBox(.{ .direction = .row, .gap = 4 });
            var i: u32 = 0;
            while (i < 2) : (i += 1) {
                c.id_stack.push(i);
                out[i] = c.colorSwatch(color, false);
                c.id_stack.pop();
            }
            c.endBox();
        }
    }.f;

    // フレーム1: 構築（同色 2 個。ID が衝突していれば endFrame の assert で落ちる）
    ctx.beginFrame(800, 600);
    build(&ctx, same, &res);
    ctx.endFrame();

    // フレーム2: 2 個目（x = 18 + gap 4 = 22 起点）の中心を click → 2 個目だけ clicked
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 22 + 9, 9);
    build(&ctx, same, &res);
    ctx.endFrame();
    try std.testing.expect(!res[0]);
    try std.testing.expect(res[1]);
}

test "colorSwatch: hit-test の rect 境界が正確（右下 -1px は in / 右下端は out）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const opts: SwatchOpts = .{ .color = Color.rgba(0x40, 0x80, 0xC0, 0xFF) };

    // swatch 単体 → rect = (0,0,18,18)
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(7, opts);
    ctx.endFrame();
    const rect = ctx.getNodeRect(7).?;
    try std.testing.expectEqual(@as(u32, 18), rect.w);

    // 右下の内側 1px（17,17）→ clicked
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 17, 17);
    try std.testing.expect(ctx.colorSwatchId(7, opts).clicked);
    ctx.endFrame();

    // 右下端（18,18）は exclusive → ヒットしない
    ctx.beginFrame(800, 600);
    clickAt(&ctx, 18, 18);
    const res = ctx.colorSwatchId(7, opts);
    try std.testing.expect(!res.clicked);
    try std.testing.expect(!res.hovered);
    ctx.endFrame();
}

test "colorSwatch: selected の太枠が pixel で判別できる（AC#4）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const fill = Color.rgba(0xD0, 0x46, 0x48, 0xFF);

    ctx.beginFrame(100, 30);
    ctx.beginBox(.{ .direction = .row, .gap = 4 });
    _ = ctx.colorSwatchId(1, .{ .color = fill, .selected = true });
    _ = ctx.colorSwatchId(2, .{ .color = fill });
    ctx.endBox();
    ctx.endFrame();

    var pixels: [100 * 30]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 100, .height = 30 };
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const sel = ctx.getNodeRect(1).?;
    const unsel = ctx.getNodeRect(2).?;
    const my_sel: u32 = @intCast(sel.y + 9); // 縦中央（上下帯の外）
    const border_sel: u32 = @bitCast(ctx.style.border_hover);
    const border_n: u32 = @bitCast(ctx.style.border);
    const fill_u: u32 = @bitCast(fill);

    // selected（厚さ2）: x+0, x+1 とも枠色、x+2 は塗り
    try std.testing.expectEqual(border_sel, pixels[my_sel * 100 + @as(u32, @intCast(sel.x))]);
    try std.testing.expectEqual(border_sel, pixels[my_sel * 100 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(fill_u, pixels[my_sel * 100 + @as(u32, @intCast(sel.x + 2))]);
    // 非 selected（厚さ1）: x+0 は枠色、x+1 から塗り → 枠幅で視覚差別できる
    try std.testing.expectEqual(border_n, pixels[my_sel * 100 + @as(u32, @intCast(unsel.x))]);
    try std.testing.expectEqual(fill_u, pixels[my_sel * 100 + @as(u32, @intCast(unsel.x + 1))]);
}

test "button: selected の太枠が pixel で判別できる（AC#4）" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(200, 40);
    ctx.beginBox(.{ .direction = .row, .gap = 8 });
    _ = ctx.buttonEx("Pen", .{ .selected = true });
    _ = ctx.buttonEx("Eraser", .{});
    ctx.endBox();
    ctx.endFrame();

    var pixels: [200 * 40]u32 = undefined;
    @memset(&pixels, 0xFF000000);
    const target: geom.RenderTarget = .{ .pixels = &pixels, .width = 200, .height = 40 };
    render_mod.render(target, &ctx.draw_list, ctx.font);

    const sel = ctx.getNodeRect(ctx.id_stack.make("Pen")).?;
    const unsel = ctx.getNodeRect(ctx.id_stack.make("Eraser")).?;
    const border_u: u32 = @bitCast(ctx.style.border);
    const bg_u: u32 = @bitCast(ctx.style.bg);
    const ys: u32 = @intCast(sel.y + @as(i32, @intCast(sel.h / 2)));
    const yu: u32 = @intCast(unsel.y + @as(i32, @intCast(unsel.h / 2)));

    // selected（厚さ2）: x+1 も枠色 / 非 selected（厚さ1）: x+1 は bg
    try std.testing.expectEqual(border_u, pixels[ys * 200 + @as(u32, @intCast(sel.x + 1))]);
    try std.testing.expectEqual(bg_u, pixels[yu * 200 + @as(u32, @intCast(unsel.x + 1))]);
}

test "buttonId: getNodeRect で rect が取れ、min_w が効く" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    ctx.beginBox(.{ .direction = .column, .gap = 4 });
    _ = ctx.buttonId(77, "Save", .{});
    _ = ctx.buttonId(78, "OK", .{ .min_w = 60 });
    _ = ctx.buttonId(79, "VeryLongLabel", .{ .min_w = 10 });
    ctx.endBox();
    ctx.endFrame();

    // "Save" = 4 文字 × 8px + padding 左右 8+8 = 48、高さ = 16 + 4+4 = 24
    const save = ctx.getNodeRect(77).?;
    try std.testing.expectEqual(@as(u32, 48), save.w);
    try std.testing.expectEqual(@as(u32, 24), save.h);
    // min_w が text+padding より大きい → min_w
    try std.testing.expectEqual(@as(u32, 60), ctx.getNodeRect(78).?.w);
    // min_w が小さい → text+padding（13×8+16 = 120）
    try std.testing.expectEqual(@as(u32, 120), ctx.getNodeRect(79).?.w);
}

test "button: held フレームは bg_active、hover フレームは bg_hover で塗られる" {
    var ctx = testCtx();
    defer ctx.deinit();

    // フレーム1: キャッシュ生成
    ctx.beginFrame(800, 600);
    _ = ctx.button("Btn");
    ctx.endFrame();
    const c = center(ctx.getNodeRect(ctx.id_stack.make("Btn")).?);

    // フレーム2: hover のみ（hot_id はまだ前フレーム値 0 → bg のまま、next_hot に積まれる）
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // フレーム3: hover 継続（hot_id 昇格済み）→ bg_hover
    ctx.beginFrame(800, 600);
    moveTo(&ctx, c.x, c.y);
    _ = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_hover)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));

    // フレーム4: press → held → bg_active
    ctx.beginFrame(800, 600);
    pressAt(&ctx, c.x, c.y);
    const res = ctx.button("Btn");
    ctx.endFrame();
    try std.testing.expect(!res);
    try std.testing.expectEqual(@as(u32, @bitCast(ctx.style.bg_active)), @as(u32, @bitCast(ctx.draw_list.cmds.items[0].rect_filled.color)));
}

test "colorSwatch: 不透明は bg+枠のみ、半透明は checker+blend で発行される" {
    var ctx = testCtx();
    defer ctx.deinit();

    // 不透明: rect_filled(色) + rect_outline = 2 cmd
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(1, .{ .color = Color.rgba(0xFF, 0x00, 0x00, 0xFF) });
    ctx.endFrame();
    try std.testing.expectEqual(@as(usize, 2), ctx.draw_list.cmds.items.len);
    try std.testing.expect(ctx.draw_list.cmds.items[0] == .rect_filled);
    try std.testing.expect(ctx.draw_list.cmds.items[1] == .rect_outline);

    // 半透明: checker（18px / 4px cell = 5×5）+ blend 塗り + 枠 = 27 cmd。
    // 最後の rect_filled が半透明色そのもの（blend は render 時）
    const translucent = Color.rgba(0x00, 0xFF, 0x00, 0x80);
    ctx.beginFrame(800, 600);
    _ = ctx.colorSwatchId(1, .{ .color = translucent });
    ctx.endFrame();
    const cmds = ctx.draw_list.cmds.items;
    try std.testing.expectEqual(@as(usize, 27), cmds.len);
    try std.testing.expect(cmds[cmds.len - 1] == .rect_outline);
    try std.testing.expectEqual(
        @as(u32, @bitCast(translucent)),
        @as(u32, @bitCast(cmds[cmds.len - 2].rect_filled.color)),
    );
}

test "widgets: 初回フレーム（キャッシュ未生成）は click が成立しない（契約の確認）" {
    var ctx = testCtx();
    defer ctx.deinit();

    ctx.beginFrame(800, 600);
    clickAt(&ctx, 5, 5); // ボタンが置かれる位置を先に click
    try std.testing.expect(!ctx.button("Btn"));
    try std.testing.expect(!ctx.wantsMouse());
    ctx.endFrame();
}

// ── Slider テスト（TASK-21.9）─────────────────────────────
const SLIDER_ID: Id = 900;

/// frame1 でキャッシュ生成し track rect を返す。
fn sliderFrame1I32(ctx: *Context, value: *i32, opts: SliderI32Opts) Rect {
    ctx.beginFrame(800, 600);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", value, opts);
    ctx.endFrame();
    return ctx.getNodeRect(SLIDER_ID).?;
}

fn trackCenterY(track: Rect) i32 {
    return track.y + @divTrunc(@as(i32, @intCast(track.h)), 2);
}

test "slider: knobRectFor は frac=0/1 で中心が track 両端（可動域）" {
    const track = Rect{ .x = 10, .y = 0, .w = 120, .h = 16 };
    const k0 = knobRectFor(track, 10, 16, 0);
    const k1 = knobRectFor(track, 10, 16, 1);
    try std.testing.expectEqual(@as(i32, 10), k0.x); // 中心 15 = x+knob_w/2 → x=10
    try std.testing.expectEqual(@as(i32, 120), k1.x); // 中心 125 = x+w-knob_w/2 → x=120
}

test "slider: ドラッグで *value が更新され [min,max] clamp（AC#2）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2); // v=0 の knob 中心
    const yc = trackCenterY(track);

    // frame2: knob を掴んで track 右端の外まで drag → max に clamp
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    moveTo(&ctx, track.x + @as(i32, @intCast(track.w)) + 50, yc);
    const changed = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(i32, 100), v);
}

test "slider: step 指定で値が step 単位に丸められる（AC#3）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 10, .step = 2 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const yc = trackCenterY(track);

    // track の 35% 位置へ drag: span=110, x=lo+38 → t=0.3454 → raw≈3.45 → round(3.45/2)*2 = 4
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    const span = @as(i32, @intCast(track.w)) - kw;
    moveTo(&ctx, lo + @divTrunc(span * 35, 100), yc);
    _ = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expectEqual(@as(i32, 4), v); // step=2 単位に丸め（固定期待値）
}

test "slider: track 上だが knob 外の press では値が変わらない（AC#4）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: i32 = 0;
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    const track = sliderFrame1I32(&ctx, &v, opts);
    const yc = trackCenterY(track);

    // v=0 の knob は左端。track 右端付近（knob 外）を press して drag → active 取得されず不変
    ctx.beginFrame(800, 600);
    pressAt(&ctx, track.x + @as(i32, @intCast(track.w)) - 1, yc);
    moveTo(&ctx, track.x + 5, yc);
    const changed = ctx.sliderI32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(i32, 0), v);
}

test "slider: 値の桁数が変わっても track.x が動かない（High 回帰防止）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const opts: SliderI32Opts = .{ .min = 0, .max = 100 };

    var v: i32 = 9;
    const track9 = sliderFrame1I32(&ctx, &v, opts);
    v = 10; // 桁数増加（値テキストは track の右なので track 位置に無影響のはず）
    const track10 = sliderFrame1I32(&ctx, &v, opts);

    try std.testing.expectEqual(track9.x, track10.x);
    try std.testing.expectEqual(track9.w, track10.w);
}

test "sliderF32: clamp + step が効く" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: f32 = 0;
    const opts: SliderF32Opts = .{ .min = 0, .max = 1, .step = 0.25 };

    ctx.beginFrame(800, 600);
    _ = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();
    const track = ctx.getNodeRect(SLIDER_ID).?;
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const yc = trackCenterY(track);

    // 右端外まで drag → 1.0 に clamp（0.25 の倍数）
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    moveTo(&ctx, track.x + @as(i32, @intCast(track.w)) + 50, yc);
    const changed = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v, 0.001);
}

test "sliderF32: 中間ドラッグで step 単位に丸まる（AC#3 の f32 回帰）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var v: f32 = 0;
    const opts: SliderF32Opts = .{ .min = 0, .max = 1, .step = 0.25 };

    ctx.beginFrame(800, 600);
    _ = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();
    const track = ctx.getNodeRect(SLIDER_ID).?;
    const kw = ctx.style.slider_knob_w;
    const lo = track.x + @divTrunc(kw, 2);
    const yc = trackCenterY(track);

    // 30% 位置へ drag: span=110, x=lo+33 → t=0.30 → raw=0.30 → round(0.30/0.25)*0.25 = 0.25
    ctx.beginFrame(800, 600);
    pressAt(&ctx, lo, yc);
    const span = @as(i32, @intCast(track.w)) - kw;
    moveTo(&ctx, lo + @divTrunc(span * 30, 100), yc);
    _ = ctx.sliderF32Id(SLIDER_ID, "S", &v, opts);
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, 0.25), v, 0.001); // step なしなら ≈0.30
}

// ── HSV ピッカー テスト（TASK-21.14）─────────────────────
const PICKER_ID: Id = 901;

test "svSquare: 領域内ドラッグで s,v が更新され [0,1] clamp（AC#2）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0;
    var v: f32 = 1;

    // frame1: キャッシュ生成（size 固定 64 で検証）
    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // frame2: 右下端の外まで drag → s=1, v=0（下=暗）。clamp 確認
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 5, r.y + 5);
    moveTo(&ctx, r.x + @as(i32, @intCast(r.w)) + 50, r.y + @as(i32, @intCast(r.h)) + 50);
    const changed = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v, 0.001);
}

test "svSquare: 領域外 press では active を取得しない（hit-test 領域限定）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0.5;
    var v: f32 = 0.5;

    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // square の外を press → drag。値は変わらない
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + @as(i32, @intCast(r.w)) + 30, r.y + 5);
    moveTo(&ctx, r.x + 10, r.y + 10);
    const changed = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 64 });
    ctx.endFrame();

    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(f32, 0.5), s);
    try std.testing.expectEqual(@as(f32, 0.5), v);
}

test "svSquare: dl.image が発行される" {
    var ctx = testCtx();
    defer ctx.deinit();
    var s: f32 = 0.3;
    var v: f32 = 0.7;

    ctx.beginFrame(800, 600);
    _ = ctx.svSquareId(PICKER_ID, 0, &s, &v, .{ .size = 32 });
    ctx.endFrame();

    var has_image = false;
    for (ctx.draw_list.cmds.items) |cmd| {
        if (cmd == .image) {
            has_image = true;
            try std.testing.expectEqual(@as(u32, 32), cmd.image.src_w);
            try std.testing.expectEqual(@as(u32, 32), cmd.image.src_h);
        }
    }
    try std.testing.expect(has_image);
}

test "hueBar: ドラッグで h が [0,360) で更新される（AC#3）" {
    var ctx = testCtx();
    defer ctx.deinit();
    var h: f32 = 0;

    ctx.beginFrame(800, 600);
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();
    const r = ctx.getNodeRect(PICKER_ID).?;

    // 下端の外まで drag → h は 360 未満の最大付近
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 8, r.y + 2);
    moveTo(&ctx, r.x + 8, r.y + @as(i32, @intCast(r.h)) + 50);
    const changed = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();

    try std.testing.expect(changed);
    try std.testing.expect(h >= 0 and h < 360);
    try std.testing.expect(h > 300); // 下端付近は高い hue

    // 中ほどへ drag → 約 180
    ctx.beginFrame(800, 600);
    pressAt(&ctx, r.x + 8, r.y + @as(i32, @intCast(r.h)) + 50); // active 継続のため一度離さず再 press 不要だが明示
    moveTo(&ctx, r.x + 8, r.y + @as(i32, @intCast(@divTrunc(r.h, 2))));
    _ = ctx.hueBarId(PICKER_ID, &h, .{ .w = 16, .h = 64 });
    ctx.endFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 180), h, 20);
}

test "imageBox: 固定 w×h の leaf を確保し等倍 image cmd を発行する" {
    var ctx = testCtx();
    defer ctx.deinit();

    const W: i32 = 24;
    const H: i32 = 20;
    var buf: [24 * 20]u32 = undefined;
    @memset(buf[0..], 0xFF112233);

    ctx.beginFrame(200, 200);
    ctx.imageBox(0xBEEF, &buf, W, H, .{});
    ctx.endFrame(); // endFrame が custom draw_fn を呼び dl.image(rect.w==src_w を assert) を実行

    // 固定サイズの leaf が確保される（dl.image の等倍契約の前提）
    const rect = ctx.getNodeRect(0xBEEF).?;
    try std.testing.expectEqual(@as(u32, 24), rect.w);
    try std.testing.expectEqual(@as(u32, 20), rect.h);

    // image cmd が src_w/src_h・rect.w 一致で 1 つ発行されている
    var found = false;
    for (ctx.draw_list.cmds.items) |cmd| switch (cmd) {
        .image => |im| {
            try std.testing.expectEqual(@as(u32, 24), im.src_w);
            try std.testing.expectEqual(@as(u32, 20), im.src_h);
            try std.testing.expectEqual(@as(u32, 24), im.rect.w);
            try std.testing.expectEqual(@as(u32, 20), im.rect.h);
            found = true;
        },
        else => {},
    };
    try std.testing.expect(found);
}

fn buildFixedContent(ctx: *Context, child_id: Id, w: i32, h: i32) void {
    ctx.beginBox(.{ .id = child_id, .width = .{ .fixed = w }, .height = .{ .fixed = h } });
    ctx.endBox();
}

test "scrollArea: 前フレーム自然サイズで縦 scroll を clamp し content をオフセット・縦バーを出す" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x5C0011;
    const CHILD: Id = 0xC0FFEE11;
    var scroll: Vec2f = .{};
    const VP_W: i32 = 100;
    const VP_H: i32 = 60;
    const CONTENT_W: i32 = 80; // viewport より狭い → 横 scroll 不要
    const CONTENT_H: i32 = 200; // viewport より高い → 縦 scroll 要
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = VP_W }, .height = .{ .fixed = VP_H } };

    // frame1: scroll=0 で配置（前フレーム cache が無いので bar は未確定 → まだ出ない）
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, CONTENT_W, CONTENT_H);
    ctx.endScrollArea();
    ctx.endFrame();
    const vp = ctx.getNodeRect(SID).?;
    try std.testing.expectEqual(@as(u32, @intCast(VP_W)), vp.w); // bar 未出なので全幅

    // frame2: 過大 scroll を要求 → 前フレーム自然サイズで max_y=140 に clamp、縦バー出現、content が上へ
    scroll.y = 1000;
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, CONTENT_W, CONTENT_H);
    ctx.endScrollArea();
    ctx.endFrame();

    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(CONTENT_H - VP_H)), scroll.y, 0.5); // 140 に clamp
    const vthumb_id = id_mod.hashInt(SID, 2);
    const hthumb_id = id_mod.hashInt(SID, 3);
    try std.testing.expect(ctx.rect_cache.get(vthumb_id) != null); // 縦バー出現
    try std.testing.expect(ctx.rect_cache.get(hthumb_id) == null); // 横バーは出ない
    // content の子が scroll 分だけ上へ（絶対値: viewport.y - 140）。clip 外（viewport より上）に出る。
    const child = ctx.getNodeRect(CHILD).?;
    try std.testing.expectEqual(vp.y - (CONTENT_H - VP_H), child.y);
    try std.testing.expect(child.y < vp.y);
}

test "scrollArea: 縦 thumb ドラッグで scroll.y が増える（同期ドラッグ）" {
    var ctx = testCtx();
    defer ctx.deinit();
    const SID: Id = 0x5C0022;
    const CHILD: Id = 0xC0FFEE22;
    var scroll: Vec2f = .{};
    const opts: ScrollAreaOpts = .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 60 } };

    // frame1/2: 配置して縦バー thumb の rect cache を生成（need_v は前フレーム判定なので 2 フレーム目で出る）
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    ctx.beginFrame(300, 300);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    const vthumb_id = id_mod.hashInt(SID, 2);
    const tc = center(ctx.getNodeRect(vthumb_id).?);

    // frame3: thumb を press（active 取得）
    ctx.beginFrame(300, 300);
    pressAt(&ctx, tc.x, tc.y);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();

    // frame4: 下へドラッグ → held 中 mouse_delta.y>0 が scroll.y を増やす
    const before = scroll.y;
    ctx.beginFrame(300, 300);
    moveTo(&ctx, tc.x, tc.y + 20);
    ctx.beginScrollArea(SID, &scroll, opts);
    buildFixedContent(&ctx, CHILD, 80, 200);
    ctx.endScrollArea();
    ctx.endFrame();
    try std.testing.expect(scroll.y > before);
}
