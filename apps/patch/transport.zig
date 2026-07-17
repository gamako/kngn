//! グローバル / トランスポート操作パネル（TASK-110.5）。
//!
//! ホットパス宣言: レイアウト・slider 評価は frame-rate、変更 callback は event-rate（main thread）。
//! このファイルは Controls/モジュールを直接触らず、main の共通 setter に値を渡す。

const std = @import("std");
const kit = @import("kit");
const gui = kit.gui;

pub const ParamChangeFn = *const fn (ctx: *anyopaque, name: []const u8, value: f32) void;
pub const MuteChangeFn = *const fn (ctx: *anyopaque, name: []const u8, muted: bool) void;

const PANEL_BG = gui.Color.rgba(0x1B, 0x21, 0x29, 0xFF);
const PANEL_BORDER = gui.Color.rgba(0x50, 0x58, 0x64, 0xFF);
const TITLE = gui.Color.rgba(0xE0, 0xE6, 0xEE, 0xFF);
const SUBTLE = gui.Color.rgba(0x9A, 0xA4, 0xB0, 0xFF);

fn idFor(ctx: *const gui.Context, index: u64) gui.Id {
    return ctx.id_stack.makeInt(0x5452_4E53_0000_0000 | index);
}

fn drawGlobalSlider(
    ctx: *gui.Context,
    id: gui.Id,
    label: []const u8,
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    callback_ctx: *anyopaque,
    name: []const u8,
    on_change: ParamChangeFn,
) void {
    var current = value;
    if (ctx.sliderF32Id(id, label, &current, .{ .min = min, .max = max, .step = step, .track_w = 92 })) {
        on_change(callback_ctx, name, current);
    }
}

fn drawTrack(
    ctx: *gui.Context,
    id_base: u64,
    label: []const u8,
    gain: f32,
    muted: bool,
    callback_ctx: *anyopaque,
    on_change: ParamChangeFn,
    on_mute: MuteChangeFn,
) void {
    ctx.beginBox(.{ .direction = .row, .gap = 4, .align_cross = .center });
    var current_gain = gain;
    if (ctx.sliderF32Id(idFor(ctx, id_base), label, &current_gain, .{
        .min = 0.0,
        .max = 1.5,
        .step = 0.01,
        .track_w = 64,
    })) {
        var name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}_gain", .{label}) catch label;
        on_change(callback_ctx, name, current_gain);
    }
    var current_mute = muted;
    if (ctx.toggleId(idFor(ctx, id_base + 0x100), "M", &current_mute)) {
        on_mute(callback_ctx, label, current_mute);
    }
    ctx.endBox();
}

/// 左ペイン（transport + 余白）を共有 GUI root の 1 子として構築する。
/// `panel` は screen 座標の transportRect、`left_w` は inspector 左端。
pub fn draw(
    ctx: *gui.Context,
    panel: gui.Rect,
    left_w: i32,
    screen_h: i32,
    params: anytype,
    callback_ctx: *anyopaque,
    on_change: ParamChangeFn,
    on_mute: MuteChangeFn,
) void {
    const panel_w: i32 = @intCast(panel.w);
    const panel_h: i32 = @intCast(panel.h);
    ctx.beginBox(.{ .direction = .column, .width = .{ .fixed = @max(0, left_w) }, .height = .{ .fixed = @max(0, screen_h) } });
    ctx.beginBox(.{ .width = .{ .fixed = @max(0, panel.y) }, .height = .{ .fixed = @max(0, panel.y) } });
    ctx.endBox();
    ctx.beginBox(.{ .direction = .row, .width = .{ .fixed = @max(0, left_w) }, .height = .{ .fixed = @max(0, panel_h) } });
    ctx.beginBox(.{ .width = .{ .fixed = @max(0, panel.x) }, .height = .{ .fixed = @max(0, panel_h) } });
    ctx.endBox();
    ctx.beginBox(.{
        .width = .{ .fixed = @max(0, panel_w) },
        .height = .{ .fixed = @max(0, panel_h) },
        .padding = .{ 10, 10, 10, 10 },
        .gap = 5,
        .bg = PANEL_BG,
        .border = .{ .color = PANEL_BORDER, .thickness = 1 },
        .clip_children = true,
    });
    ctx.labelEx("TRANSPORT", TITLE);
    ctx.labelEx("global / track controls", SUBTLE);

    ctx.beginBox(.{ .direction = .row, .gap = 10, .align_cross = .start });
    const col_w: i32 = @max(1, @divTrunc(panel_w - 30, 2));
    ctx.beginBox(.{ .width = .{ .fixed = col_w }, .height = .fit, .gap = 3 });
    drawGlobalSlider(ctx, idFor(ctx, 1), "tempo", params.tempo, 40.0, 220.0, 1.0, callback_ctx, "tempo", on_change);
    drawGlobalSlider(ctx, idFor(ctx, 2), "cutoff", params.cutoff_norm, 0.0, 1.0, 0.01, callback_ctx, "cutoff_norm", on_change);
    drawGlobalSlider(ctx, idFor(ctx, 3), "density", params.density, 0.0, 1.0, 0.01, callback_ctx, "density", on_change);
    drawGlobalSlider(ctx, idFor(ctx, 4), "swing", params.swing, 0.0, 1.0, 0.01, callback_ctx, "swing", on_change);
    drawGlobalSlider(ctx, idFor(ctx, 5), "sidechain", params.sidechain, 0.0, 1.0, 0.01, callback_ctx, "sidechain", on_change);
    ctx.endBox();

    ctx.beginBox(.{ .width = .{ .fixed = col_w }, .height = .fit, .gap = 3 });
    ctx.labelEx("TRACK GAINS / MUTE", SUBTLE);
    drawTrack(ctx, 10, "kick", params.kick_gain, params.kick_mute, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 11, "hat", params.hat_gain, params.hat_mute, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 12, "clap", params.clap_gain, params.clap_mute, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 13, "bass", params.bass_gain, params.bass_mute, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 14, "pad", params.pad_gain, params.pad_mute, callback_ctx, on_change, on_mute);
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
}
