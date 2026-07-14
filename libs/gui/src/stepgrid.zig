//! 16-step grid の共通描画・幾何・Flex widget。
//!
//! grid はフレーム毎に最大 16×5 セルを描くが、全画素ループではない（セル矩形を
//! DrawList へ積むだけ）。このため SIMD/全画素ループ規約の対象外で、widget 側の
//! 一時データは Context の per-frame arena に置く。

const std = @import("std");
const context_mod = @import("context.zig");
const draw_mod = @import("draw.zig");
const color_mod = @import("color.zig");
const geom_mod = @import("geom.zig");
const layout_mod = @import("layout.zig");

pub const Context = context_mod.Context;
pub const DrawList = draw_mod.DrawList;
pub const Color = color_mod.Color;
pub const Rect = geom_mod.Rect;
pub const Id = u64;

pub const STEP_COUNT: u8 = 16;

/// world/screen の f32 幾何。呼び出し側が camera 変換を済ませて渡す。
pub const Geometry = struct {
    origin_x: f32,
    origin_y: f32,
    cell_w: f32,
    cell_h: f32,
    step_pitch: f32,
    row_pitch: f32,

    pub fn cellRect(self: Geometry, row_index: u8, step: u8) RectF {
        return .{
            .x = self.origin_x + @as(f32, @floatFromInt(step)) * self.step_pitch,
            .y = self.origin_y + @as(f32, @floatFromInt(row_index)) * self.row_pitch,
            .w = self.cell_w,
            .h = self.cell_h,
        };
    }
};

pub const RectF = struct { x: f32, y: f32, w: f32, h: f32 };
pub const GridCell = struct { row: u8, step: u8 };

/// 現行 patch grid の配色を共通既定値にする。modular もこの値を使う。
pub const DEFAULT_OFF = Color.rgba(0x30, 0x38, 0x42, 0xFF);
pub const DEFAULT_OFF_BEAT = DEFAULT_OFF; // patch の既存見た目では拍頭も同色
pub const DEFAULT_ON = Color.rgba(0xE0, 0x90, 0x40, 0xFF);
pub const DEFAULT_ACCENT = Color.rgba(0xE0, 0xC0, 0x50, 0xFF);
pub const DEFAULT_SLIDE = Color.rgba(0x50, 0x90, 0xE0, 0xFF);
pub const DEFAULT_PITCH = Color.rgba(0x60, 0xC0, 0x70, 0xFF);
pub const DEFAULT_PLAYHEAD = Color.rgba(0xF0, 0xF0, 0xF0, 0x60);

pub const PitchStyle = enum { cells, bars };

pub const PitchRow = struct {
    degrees: []const i8,
    degree_count: usize,
    color: Color = DEFAULT_PITCH,
    /// `.cells` はセル全体を degree 色で塗る modular 旧実装、`.bars` は
    /// off 下地 + 下端バーの patch 旧実装。
    style: PitchStyle = .bars,
};

pub const DrawRow = struct {
    mask: ?u16 = null,
    on_color: Color = DEFAULT_ON,
    pitch: ?PitchRow = null,
};

pub const DrawOptions = struct {
    off_color: Color = DEFAULT_OFF,
    off_beat_color: Color = DEFAULT_OFF_BEAT,
    playhead: ?u4 = null,
    playhead_color: Color = DEFAULT_PLAYHEAD,
};

pub const WidgetOptions = struct {
    id_base: Id,
    mask: ?u16 = null,
    on_color: Color = DEFAULT_ON,
    pitch: ?PitchRow = null,
    cell_size: i32 = 16,
    editable: bool = true,
    off_color: Color = DEFAULT_OFF,
    off_beat_color: Color = DEFAULT_OFF_BEAT,
};

/// grid の拍頭を含む off 色を返す。
pub fn offColor(step: u8, off_color: Color, off_beat_color: Color) Color {
    return if (step % 4 == 0) off_beat_color else off_color;
}

/// degree を表示可能な index へ clamp する。
fn pitchDegree(pitch: PitchRow, step: u8) i32 {
    return std.math.clamp(@as(i32, pitch.degrees[step]), 0, @as(i32, @intCast(@max(pitch.degree_count, 1) - 1)));
}

/// modular 旧実装の pitch セル色。color field ではなく、旧式の固定 RGB 式を保つ。
fn pitchCellsColor(pitch: PitchRow, step: u8) Color {
    const degree = pitchDegree(pitch, step);
    const t: f32 = if (pitch.degree_count <= 1)
        0
    else
        @as(f32, @floatFromInt(degree)) / @as(f32, @floatFromInt(pitch.degree_count - 1));
    return Color.rgba(
        0x30,
        @intFromFloat(70.0 + t * 170.0),
        0x50,
        0xFF,
    );
}

fn bitSet(mask: u16, step: u8) bool {
    return (mask >> @as(u4, @intCast(step))) & 1 == 1;
}

/// f32 の矩形を DrawList の整数矩形へ変換する。camera の極端な zoom/pan でも
/// 不正な値を DrawList へ渡さない。
fn toRect(rect: RectF) Rect {
    const safeI32 = struct {
        fn convert(v: f32) i32 {
            if (!std.math.isFinite(v)) return 0;
            return @intFromFloat(std.math.clamp(@round(v), -1_000_000.0, 1_000_000.0));
        }
    }.convert;
    const safeU32 = struct {
        fn convert(v: f32) u32 {
            if (!std.math.isFinite(v)) return 0;
            return @intFromFloat(std.math.clamp(@round(v), 0.0, 1_000_000.0));
        }
    }.convert;
    return .{ .x = safeI32(rect.x), .y = safeI32(rect.y), .w = safeU32(rect.w), .h = safeU32(rect.h) };
}

fn drawRect(dl: *DrawList, rect: RectF, color: Color) void {
    dl.rectFilled(toRect(rect), color) catch @panic("stepgrid.draw: DrawList OOM");
}

/// rows の 16 step を描く。playhead は null なら表示しない。
pub fn draw(dl: *DrawList, geometry: Geometry, rows: []const DrawRow, options: DrawOptions) void {
    for (rows, 0..) |draw_row, row_index| {
        const row_u8: u8 = @intCast(row_index);
        var step: u8 = 0;
        while (step < STEP_COUNT) : (step += 1) {
            const cell = geometry.cellRect(row_u8, step);
            const base = if (draw_row.pitch) |pitch|
                if (pitch.style == .cells) pitchCellsColor(pitch, step) else offColor(step, options.off_color, options.off_beat_color)
            else if (draw_row.mask) |mask|
                if (bitSet(mask, step)) draw_row.on_color else offColor(step, options.off_color, options.off_beat_color)
            else
                offColor(step, options.off_color, options.off_beat_color);
            drawRect(dl, cell, base);

            // patch 旧実装の段表示はセル下端から伸ばす。modular の `.cells` にはバーを足さない。
            if (draw_row.pitch) |pitch| if (pitch.style == .bars) {
                const degree = @as(f32, @floatFromInt(pitch.degrees[step]));
                const fraction = if (pitch.degree_count == 0)
                    0.0
                else
                    std.math.clamp(degree / @as(f32, @floatFromInt(pitch.degree_count)), 0.0, 1.0);
                const bar_h = @max(1.0, cell.h * std.math.clamp(fraction, 0.0, 1.0));
                drawRect(dl, .{ .x = cell.x, .y = cell.y + cell.h - bar_h, .w = cell.w, .h = bar_h }, pitch.color);
            };
            // playhead は mask 行のみ（patch 旧実装は pitch 段に playhead を重ねない）
            if (options.playhead) |playhead| {
                if (step == playhead and draw_row.pitch == null) drawRect(dl, cell, options.playhead_color);
            }
        }
    }
}

/// 点が grid のセルに入っているかを判定する。cell 間 gap は null。
pub fn hitTest(geometry: Geometry, point_x: f32, point_y: f32, row_count: u8) ?GridCell {
    var row_index: u8 = 0;
    while (row_index < row_count and row_index < 255) : (row_index += 1) {
        var step: u8 = 0;
        while (step < STEP_COUNT) : (step += 1) {
            const cell = geometry.cellRect(row_index, step);
            if (point_x >= cell.x and point_x <= cell.x + cell.w and
                point_y >= cell.y and point_y <= cell.y + cell.h)
            {
                return .{ .row = row_index, .step = step };
            }
        }
    }
    return null;
}

/// 現在の Flex 親へ 16 個のセルを追加し、クリックされたセルを返す。
/// セル ID は id_base + step の明示 ID で、呼び出し側の label/button と衝突しない値を渡す。
pub fn widgetRow(ctx: *Context, options: WidgetOptions) ?GridCell {
    std.debug.assert(options.cell_size > 0);
    var clicked: ?GridCell = null;
    var step: u8 = 0;
    while (step < STEP_COUNT) : (step += 1) {
        const id = options.id_base + step;
        const result = if (ctx.getNodeCachedRect(id)) |cached|
            context_mod.buttonBehavior(ctx, id, cached.rect, cached.clip)
        else
            context_mod.ButtonResult{};
        if (options.editable and result.clicked) clicked = .{ .row = 0, .step = step };

        const color = if (options.pitch) |pitch|
            pitchCellsColor(pitch, step)
        else if (options.mask) |mask|
            if (bitSet(mask, step)) options.on_color else offColor(step, options.off_color, options.off_beat_color)
        else
            offColor(step, options.off_color, options.off_beat_color);
        // colorSwatchId の不透明経路と同じ box bg + style 枠（クリック可能セルの見た目を widget 群と揃える）
        const style = ctx.style;
        const border: ?layout_mod.Border = if (style.swatch_border <= 0)
            null
        else
            .{ .color = style.border, .thickness = @intCast(style.swatch_border) };
        ctx.beginBox(.{
            .id = id,
            .width = .{ .fixed = options.cell_size },
            .height = .{ .fixed = options.cell_size },
            .bg = color,
            .border = border,
        });
        ctx.endBox();
    }
    return clicked;
}

test "stepgrid: cell geometry and gap hit-test" {
    const geometry = Geometry{ .origin_x = 10, .origin_y = 20, .cell_w = 8, .cell_h = 6, .step_pitch = 10, .row_pitch = 8 };
    const cell = geometry.cellRect(2, 3);
    try std.testing.expectEqual(@as(f32, 40), cell.x);
    try std.testing.expectEqual(@as(f32, 36), cell.y);
    try std.testing.expectEqual(GridCell{ .row = 2, .step = 3 }, hitTest(geometry, 44, 40, 4).?);
    try std.testing.expectEqual(@as(?GridCell, null), hitTest(geometry, 48.5, 40, 4));
}

test "stepgrid: playhead is optional and rows are bounded" {
    const geometry = Geometry{ .origin_x = 0, .origin_y = 0, .cell_w = 10, .cell_h = 10, .step_pitch = 10, .row_pitch = 10 };
    try std.testing.expectEqual(GridCell{ .row = 3, .step = 15 }, hitTest(geometry, 159, 39, 4).?);
    try std.testing.expectEqual(@as(?GridCell, null), hitTest(geometry, 0, 41, 4));
}
