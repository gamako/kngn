//! グローバル / トランスポート操作パネル。
//!
//! ホットパス宣言: projection の field 読み出しと slider 評価は frame-rate、変更 callback は
//! event-rate（main thread）。このファイルは Controls/モジュールを直接触らず canonical key を返す。
//! 外形・header・open は PanelHost が所有し、ここでは body のみを構築する（TASK-149.1）。
//!
//! Collapsible body は width=.fit のため、body 内の grow は 0 に潰れる（layout 契約）。
//! 外側 box / 2 カラムは呼び出し側が測った body_w を .fixed で注入する。

const kit = @import("kit");
const gui = kit.gui;
const view = @import("param_view.zig");

pub const ParamChangeFn = *const fn (ctx: *anyopaque, key: view.FieldKey, value: f32) void;
pub const MuteChangeFn = *const fn (ctx: *anyopaque, name: []const u8, muted: bool) void;
pub const DisplayFn = *const fn (ctx: *anyopaque, key: view.FieldKey, field: f32) f32;

const SUBTLE = gui.Color.rgba(0x9A, 0xA4, 0xB0, 0xFF);
const BODY_PAD: i32 = 6;
const COL_GAP: i32 = 10;

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

/// PanelHost callback から呼ばれる body のみ。header / open / 外形は PanelHost が所有する。
/// `body_w` は panel rect 由来の外側幅（padding 込み）。fit 親内 grow collapse を避けるため .fixed で構築する。
pub fn drawBody(
    ctx: *gui.Context,
    model: *const Model,
    body_w: i32,
    display_ctx: *anyopaque,
    display: DisplayFn,
    callback_ctx: *anyopaque,
    on_change: ParamChangeFn,
    on_mute: MuteChangeFn,
) void {
    const outer_w = @max(1, body_w);
    const content_w = @max(1, outer_w - BODY_PAD * 2);
    const col_w = @max(1, @divTrunc(content_w - COL_GAP, 2));

    ctx.beginBox(.{
        .direction = .column,
        .width = .{ .fixed = outer_w },
        .gap = 5,
        .padding = .{ BODY_PAD, BODY_PAD, BODY_PAD, BODY_PAD },
    });
    ctx.labelEx("global / track controls", SUBTLE);

    ctx.beginBox(.{
        .direction = .row,
        .gap = COL_GAP,
        .align_cross = .start,
        .width = .{ .fixed = content_w },
    });
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
}
