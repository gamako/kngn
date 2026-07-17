//! グローバル / トランスポート操作パネル。
//!
//! ホットパス宣言: projection の field 読み出しと slider 評価は frame-rate、変更 callback は
//! event-rate（main thread）。このファイルは Controls/モジュールを直接触らず canonical key を返す。

const kit = @import("kit");
const gui = kit.gui;
const view = @import("param_view.zig");

pub const ParamChangeFn = *const fn (ctx: *anyopaque, key: view.FieldKey, value: f32) void;
pub const MuteChangeFn = *const fn (ctx: *anyopaque, name: []const u8, muted: bool) void;
pub const DisplayFn = *const fn (ctx: *anyopaque, key: view.FieldKey, field: f32) f32;

const PANEL_BG = gui.Color.rgba(0x1B, 0x21, 0x29, 0xFF);
const PANEL_BORDER = gui.Color.rgba(0x50, 0x58, 0x64, 0xFF);
const TITLE = gui.Color.rgba(0xE0, 0xE6, 0xEE, 0xFF);
const SUBTLE = gui.Color.rgba(0x9A, 0xA4, 0xB0, 0xFF);

pub const Scalar = struct {
    key: view.FieldKey,
    field: f32,
    instant: ?f32 = null,
};

pub const Track = struct {
    gain: Scalar,
    muted: bool,
};

pub const Model = struct {
    tempo: Scalar,
    cutoff: Scalar,
    density: Scalar,
    swing: Scalar,
    sidechain: Scalar,
    kick: Track,
    hat: Track,
    clap: Track,
    bass: Track,
    pad: Track,
    conversion: view.Conversion,
};

fn idFor(ctx: *const gui.Context, index: u64) gui.Id {
    return ctx.id_stack.makeInt(0x5452_4E53_0000_0000 | index);
}

fn displayValue(display_ctx: *anyopaque, display: DisplayFn, scalar: Scalar) f32 {
    return display(display_ctx, scalar.key, scalar.field);
}

fn drawHeader(ctx: *gui.Context, panel_w: i32, open: *bool) void {
    const label = if (open.*) "[−] TRANSPORT" else "[+] TRANSPORT";
    if (ctx.buttonId(idFor(ctx, 0), label, .{ .min_w = @max(0, panel_w - 20) }).clicked) open.* = !open.*;
}

fn drawGlobalSlider(
    ctx: *gui.Context,
    id: gui.Id,
    label: []const u8,
    alias: view.TransportAlias,
    scalar: Scalar,
    min: f32,
    max: f32,
    step: f32,
    conversion: view.Conversion,
    display_ctx: *anyopaque,
    display: DisplayFn,
    callback_ctx: *anyopaque,
    on_change: ParamChangeFn,
) void {
    const canonical = displayValue(display_ctx, display, scalar);
    var current = view.toUi(alias, canonical, conversion);
    if (ctx.sliderF32Id(id, label, &current, .{ .min = min, .max = max, .step = step, .track_w = 92 })) {
        on_change(callback_ctx, scalar.key, view.toCanonical(alias, current, conversion));
    }
}

fn drawTrack(
    ctx: *gui.Context,
    id_base: u64,
    label: []const u8,
    alias: view.TransportAlias,
    track: Track,
    conversion: view.Conversion,
    display_ctx: *anyopaque,
    display: DisplayFn,
    callback_ctx: *anyopaque,
    on_change: ParamChangeFn,
    on_mute: MuteChangeFn,
) void {
    ctx.beginBox(.{ .direction = .row, .gap = 4, .align_cross = .center });
    const canonical = displayValue(display_ctx, display, track.gain);
    var current_gain = view.gainToUi(alias, canonical, conversion);
    if (ctx.sliderF32Id(idFor(ctx, id_base), label, &current_gain, .{
        .min = 0.0,
        .max = 1.5,
        .step = 0.01,
        .track_w = 64,
    })) {
        on_change(callback_ctx, track.gain.key, view.gainToModule(alias, current_gain, conversion));
    }
    var current_mute = track.muted;
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
    model: *const Model,
    open: *bool,
    display_ctx: *anyopaque,
    display: DisplayFn,
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
    const was_open = open.*;
    drawHeader(ctx, panel_w, open);
    if (!was_open) {
        ctx.endBox();
        ctx.endBox();
        ctx.endBox();
        return;
    }
    ctx.labelEx("global / track controls", SUBTLE);

    ctx.beginBox(.{ .direction = .row, .gap = 10, .align_cross = .start });
    const col_w: i32 = @max(1, @divTrunc(panel_w - 30, 2));
    ctx.beginBox(.{ .width = .{ .fixed = col_w }, .height = .fit, .gap = 3 });
    drawGlobalSlider(ctx, idFor(ctx, 1), "tempo", .tempo, model.tempo, 40.0, 220.0, 1.0, model.conversion, display_ctx, display, callback_ctx, on_change);
    drawGlobalSlider(ctx, idFor(ctx, 2), "cutoff", .cutoff, model.cutoff, 0.0, 1.0, 0.01, model.conversion, display_ctx, display, callback_ctx, on_change);
    drawGlobalSlider(ctx, idFor(ctx, 3), "density", .density, model.density, 0.0, 1.0, 0.01, model.conversion, display_ctx, display, callback_ctx, on_change);
    drawGlobalSlider(ctx, idFor(ctx, 4), "swing", .swing, model.swing, 0.0, 1.0, 0.01, model.conversion, display_ctx, display, callback_ctx, on_change);
    drawGlobalSlider(ctx, idFor(ctx, 5), "sidechain", .sidechain, model.sidechain, 0.0, 1.0, 0.01, model.conversion, display_ctx, display, callback_ctx, on_change);
    ctx.endBox();

    ctx.beginBox(.{ .width = .{ .fixed = col_w }, .height = .fit, .gap = 3 });
    ctx.labelEx("TRACK GAINS / MUTE", SUBTLE);
    drawTrack(ctx, 10, "kick", .kick_gain, model.kick, model.conversion, display_ctx, display, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 11, "hat", .hat_gain, model.hat, model.conversion, display_ctx, display, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 12, "clap", .clap_gain, model.clap, model.conversion, display_ctx, display, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 13, "bass", .bass_gain, model.bass, model.conversion, display_ctx, display, callback_ctx, on_change, on_mute);
    drawTrack(ctx, 14, "pad", .pad_gain, model.pad, model.conversion, display_ctx, display, callback_ctx, on_change, on_mute);
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
    ctx.endBox();
}
