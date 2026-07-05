//! apps/modular (run-modular): モジュラー生成パッチを「見て・弄れる」アプリ (Ph3〜Ph5)。
//!
//! window を開き、L1 audio の RT callback で LofiPatch を render する。出力タップ→mono downmix→
//! スペクトログラム / オシロスコープ / レベルメータで可視化し、libs/gui のスライダ/ボタンで操作できる。
//! Ph5: DrumMachine（kick/hat/clap の 16 step grid）と BassMachine（303 風 on/pitch/accent/slide レーン）を
//! 追加。クリックでマス目を編集し、track ごとに lock（凍結）、全体トグル Evolve で自己進化 on/off。
//!
//! pattern 所有モデル: RT が pattern の authoritative。GUI は毎フレーム snapshot を読んで grid を表示し、
//! 編集時のみ「最新 snapshot に変更を適用した PatternCommand」を Controls.pattern_db へ publish する
//! （毎フレーム publish しない＝RT の per-bar 変異を上書きし続けない）。
//! ESC または閉じるで終了。

const std = @import("std");
const kit = @import("kit"); // 公開 umbrella（ADR-007 R4/R5: apps は kit-only 消費者）
const platform = kit.platform;
const audio = kit.audio;
const synth = kit.synth; // SampleTap（Audio→GUI の出力タップ）
const dsp = kit.dsp; // mono downmix
const gui = kit.gui; // スライダ / ボタン / グリッドセル
const spectrogram = @import("spectrogram");
const scope = @import("scope");
const patchmod = @import("patch.zig");
const LofiPatch = patchmod.LofiPatch;
const PatternCommand = patchmod.PatternCommand;
const PatchState = patchmod.PatchState;
const actions = @import("actions.zig");
const pattern_io = @import("pattern_io.zig");

// ウィンドウ。上部=GUI コントロール + DrumMachine/BassMachine、下部=可視化帯。
const WIN_W = 1120;
const WIN_H = 720;
const BG: u32 = 0xFF101418;

const VIS_Y0 = 500; // 可視化帯の上端（GUI パネルの下）
const VIS_H = 190;
const SPEC_X0 = 16;
const SPEC_W = 560;
const SCOPE_X0 = 590;
const SCOPE_W = 290;
const METER_X0 = 896;
const METER_W = 48;

const Spec = spectrogram.Spectrogram(SPEC_W, VIS_H);
const Scope = scope.Oscilloscope(SCOPE_W, VIS_H);

const Tap = synth.SampleTap(8192);

const CUTOFF_MIN: f32 = 80.0;
const CUTOFF_MAX: f32 = 18000.0;

const BASS_DEG_TOTAL: usize = patchmod.BASS_DEG_TOTAL; // bass の degree 総数（patch.zig が単一ソース）

const App = struct {
    patch: ?*LofiPatch = null,
    tap: Tap = .{},
    /// GUI スライダ/ボタンが in-place 更新する scalar パラメータ束（TASK-65: harness action からも
    /// 同じ field を書き換えられるよう main() ローカルから App へ移設）。
    params: Params = .{},
    /// GUI が publish した pattern の最新 revision（action もこのカウンタを共有し二重採番を防ぐ）。
    pattern_rev: u32 = 0,
    /// `save_pattern`/`load_pattern` action（TASK-65 serialize）が使うファイル I/O ハンドル
    /// （`std.process.Init.io`。イベント時のみ使用。RT 経路には一切渡さない）。
    io: std.Io,
};

fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata orelse {
        @memset(buf, 0);
        return;
    }));
    if (app.patch) |p| {
        p.render(buf, frames, channels);
        if (channels == 2) app.tap.write(buf);
    } else {
        @memset(buf, 0);
    }
}

// ----------------------------------------------------------------------------
// scalar スライダ/ボタンのパラメータ束（grid pattern は別管理＝snapshot 由来）。
// ----------------------------------------------------------------------------
const Params = struct {
    tempo: f32 = 122.0,
    cutoff_norm: f32 = 1.0,
    swing: f32 = 0.0,
    sidechain: f32 = 0.35,
    kick_gain: f32 = 1.0,
    hat_gain: f32 = 1.0,
    clap_gain: f32 = 1.0,
    bass_gain: f32 = 1.0,
    pad_gain: f32 = 1.0,
    kick_mute: bool = false,
    hat_mute: bool = false,
    clap_mute: bool = false,
    bass_mute: bool = false,
    pad_mute: bool = false,
    kick_punch: f32 = 1.0,
    hat_bright: f32 = 1.0,
    hat_decay: f32 = 0.045,
    pad_cutoff: f32 = 1400.0,
    pad_warmth: f32 = 0.6,
    master_warmth: f32 = 0.5,
    ambient_move: f32 = 0.4,
};

fn cutoffHz(norm: f32) f32 {
    const n = std.math.clamp(norm, 0.0, 1.0);
    return CUTOFF_MIN * std.math.pow(f32, CUTOFF_MAX / CUTOFF_MIN, n);
}

/// scalar Params を Controls(atomic) へ publish（pattern は別経路）。
fn publishControls(patch: *LofiPatch, p: Params) void {
    const c = &patch.controls;
    c.tempo_bpm.store(p.tempo);
    c.master_cutoff.store(cutoffHz(p.cutoff_norm));
    c.swing.store(p.swing);
    c.sidechain_amount.store(p.sidechain);
    c.kick_gain.store(p.kick_gain);
    c.hat_gain.store(p.hat_gain);
    c.clap_gain.store(p.clap_gain);
    c.bass_gain.store(p.bass_gain);
    c.pad_gain.store(p.pad_gain);
    c.kick_mute.store(@intFromBool(p.kick_mute), .release);
    c.hat_mute.store(@intFromBool(p.hat_mute), .release);
    c.clap_mute.store(@intFromBool(p.clap_mute), .release);
    c.bass_mute.store(@intFromBool(p.bass_mute), .release);
    c.pad_mute.store(@intFromBool(p.pad_mute), .release);
    c.kick_punch.store(p.kick_punch);
    c.hat_bright.store(p.hat_bright);
    c.hat_decay.store(p.hat_decay);
    c.pad_cutoff.store(p.pad_cutoff);
    c.pad_warmth.store(p.pad_warmth);
    c.master_warmth.store(p.master_warmth);
    c.ambient_move.store(p.ambient_move);
}

/// 現在の snapshot を pattern 編集の base（PatternCommand）へ変換する（編集はこの上に積む）。
fn stateToCommand(st: PatchState) PatternCommand {
    return .{
        .rev = st.pattern_rev,
        .evolve = st.evolve,
        .kick = .{ .on = st.kick_on, .lock = st.lock[0] },
        .hat = .{ .on = st.hat_on, .lock = st.lock[1] },
        .clap = .{ .on = st.clap_on, .lock = st.lock[2] },
        .bass = .{ .on = st.bass_on, .accent = st.bass_accent, .slide = st.bass_slide, .deg = st.bass_deg, .lock = st.lock[3] },
    };
}

inline fn bitOf(s: u8) u16 {
    return @as(u16, 1) << @as(u4, @intCast(s & 15));
}

fn buttonToU8(b: platform.MouseButton) u8 {
    return switch (b) {
        .left => 0,
        .right => 1,
        .middle => 2,
        else => 0xFF,
    };
}

fn toGuiEvent(ev: platform.Event) ?gui.InputEvent {
    return switch (ev) {
        .mouse_move => |m| .{ .mouse_move = .{ .x = m.x, .y = m.y, .modifiers = m.modifiers.toC() } },
        .mouse_down => |m| .{ .mouse_down = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        .mouse_up => |m| .{ .mouse_up = .{ .x = m.x, .y = m.y, .button = buttonToU8(m.button), .modifiers = m.modifiers.toC() } },
        else => null,
    };
}

// ----------------------------------------------------------------------------
// DrumMachine / BassMachine UI（colorSwatchId で独立クリック可能なセル grid。明示 ID）。
// ----------------------------------------------------------------------------
const CELL: i32 = 16;
const DIM = gui.Color.rgba(0x2A, 0x2E, 0x36, 0xFF); // off セル
const DIM_BEAT = gui.Color.rgba(0x3A, 0x40, 0x4A, 0xFF); // off セル（4 拍頭の目印）
const LOCK_COL = gui.Color.rgba(0xC0, 0x60, 0x60, 0xFF);

const DRUM_CELL_BASE: u64 = 0x8000;
const BASS_CELL_BASE: u64 = 0x8200;
const TOGGLE_BASE: u64 = 0x8400;

fn cellOffColor(step: u8) gui.Color {
    return if (step % 4 == 0) DIM_BEAT else DIM;
}

/// 1 本の drum track 行を描く。clicked なセルがあれば cmd を編集して edited=true。
/// 行末に Lock トグル（自己進化からそのトラックを凍結）。自己進化 on/off は全体トグル。
fn drumRow(
    ctx: *gui.Context,
    track: u64,
    label: []const u8,
    on_color: gui.Color,
    on_mask: *u16,
    lock: *bool,
    edited: *bool,
) void {
    ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
    ctx.label(label);
    var s: u8 = 0;
    while (s < 16) : (s += 1) {
        const on = (on_mask.* & bitOf(s)) != 0;
        const col = if (on) on_color else cellOffColor(s);
        const id: u64 = DRUM_CELL_BASE + track * 16 + s;
        if (ctx.colorSwatchId(id, .{ .color = col, .size = CELL }).clicked) {
            on_mask.* ^= bitOf(s);
            edited.* = true;
        }
    }
    if (ctx.buttonId(TOGGLE_BASE + track, if (lock.*) "Lock: on" else "Lock: off", .{ .selected = lock.* }).clicked) {
        lock.* = !lock.*;
        edited.* = true;
    }
    ctx.endBox();
}

/// degree(0..total-1) を緑系の明るさへ。
fn pitchColor(deg: i8) gui.Color {
    const d: f32 = @floatFromInt(std.math.clamp(@as(i32, deg), 0, @as(i32, BASS_DEG_TOTAL) - 1));
    const t = d / @as(f32, @floatFromInt(BASS_DEG_TOTAL - 1));
    const g: u8 = @intFromFloat(70.0 + t * 170.0);
    return gui.Color.rgba(0x30, g, 0x50, 0xFF);
}

pub fn main(init: std.process.Init) !void {
    std.debug.print("apps/modular: lofi テクノ生成パッチ（grid 編集・スライダ操作・ESC で終了）\n", .{});

    const allocator = std.heap.c_allocator;

    const app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = .{ .io = init.io }; // save_pattern/load_pattern action（TASK-65 serialize）用

    const spec = try allocator.create(Spec);
    defer allocator.destroy(spec);
    spec.init(48000);
    const osc = try allocator.create(Scope);
    defer allocator.destroy(osc);
    osc.* = .{};
    var meter = scope.LevelMeter{};

    // scalar パラメータ束 / pattern revision カウンタは App.params / App.pattern_rev（TASK-65。
    // harness action からも同じ field を書き換えられるよう main() ローカルから App へ移設）。

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "modular - lofi techno (DrumMachine / BassMachine)");
    defer window.destroy();

    var ctx = gui.Context.init(allocator, gui.default_font);
    defer ctx.deinit();

    const device = audio.open(allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = audioCallback,
        .userdata = app,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.close();

    const sr: f32 = @floatFromInt(device.config().sample_rate);
    const patch = LofiPatch.create(allocator, sr) catch |err| {
        std.debug.print("patch init failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer patch.destroy();
    app.patch = patch;
    spec.setSampleRate(sr);

    device.start() catch |err| {
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.stop();

    platform.registerProbe(.{ .name = "modular", .ctx = app, .ext = "json", .snapshot = modularSnapshot, .digest = modularDigest });
    // ヘッドレス検証 harness の custom action を登録（harness 無効時は no-op。TASK-65）。
    registerActions(app);

    var stereo: [2048]f32 = undefined;
    var mono: [1024]f32 = undefined;
    var running = true;

    main_loop: while (running and window.pollEvents()) {
        const fb = window.lockFramebuffer() orelse continue :main_loop;
        defer fb.unlock();

        ctx.beginFrame(fb.width, fb.height);

        while (window.nextEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |k| {
                    if (k.key == .ESCAPE) running = false;
                },
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        while (true) {
            const n = app.tap.read(&stereo);
            if (n < 2) break;
            const frames = n / 2;
            dsp.downmixStereoToMono(stereo[0 .. frames * 2], mono[0..frames]);
            spec.feed(mono[0..frames]);
            osc.feed(mono[0..frames]);
            meter.feed(mono[0..frames]);
        }

        // 現在の pattern を snapshot から取得（RT 所有・torn 可）。編集はこの上に積む。
        const st = patch.snapshotState();
        var cmd = stateToCommand(st);
        var edited = false;

        // GUI パネル（上部）
        ctx.beginBox(.{
            .direction = .column,
            .padding = .{ 10, 10, 10, 10 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });
        ctx.label("modular - lofi techno (drag sliders / click cells; Evolve=self-mutate, Lock=freeze track):");
        // scalar コントロール（3 カラム）
        ctx.beginBox(.{ .direction = .row, .gap = 18 });
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x7001, "Tempo    ", &app.params.tempo, .{ .min = 60, .max = 180, .step = 1 });
        _ = ctx.sliderF32Id(0x7002, "Cutoff   ", &app.params.cutoff_norm, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x7004, "Swing    ", &app.params.swing, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x7005, "Sidechain", &app.params.sidechain, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x7011, "Ambient  ", &app.params.ambient_move, .{ .min = 0, .max = 1, .step = 0.02 });
        ctx.endBox();
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x7006, "Kick Gain", &app.params.kick_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x7007, "Hat Gain ", &app.params.hat_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x7008, "Clap Gain", &app.params.clap_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x7009, "Bass Gain", &app.params.bass_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x700A, "Pad Level", &app.params.pad_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        ctx.endBox();
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x700B, "KickPunch", &app.params.kick_punch, .{ .min = 0, .max = 2, .step = 0.05 });
        _ = ctx.sliderF32Id(0x700C, "Hat Bright", &app.params.hat_bright, .{ .min = 0.3, .max = 2.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x700E, "Pad Cutoff", &app.params.pad_cutoff, .{ .min = 200, .max = 6000, .step = 50 });
        _ = ctx.sliderF32Id(0x700F, "Pad Warm ", &app.params.pad_warmth, .{ .min = 0, .max = 1, .step = 0.02 });
        _ = ctx.sliderF32Id(0x7010, "Mst Warm ", &app.params.master_warmth, .{ .min = 0, .max = 1, .step = 0.02 });
        ctx.endBox();
        ctx.endBox();
        // mute ボタン行
        ctx.beginBox(.{ .direction = .row, .gap = 8 });
        if (ctx.button(if (app.params.kick_mute) "Kick: MUTE" else "Kick: on")) app.params.kick_mute = !app.params.kick_mute;
        if (ctx.button(if (app.params.hat_mute) "Hat: MUTE" else "Hat: on")) app.params.hat_mute = !app.params.hat_mute;
        if (ctx.button(if (app.params.clap_mute) "Clap: MUTE" else "Clap: on")) app.params.clap_mute = !app.params.clap_mute;
        if (ctx.button(if (app.params.bass_mute) "Bass: MUTE" else "Bass: on")) app.params.bass_mute = !app.params.bass_mute;
        if (ctx.button(if (app.params.pad_mute) "Pad: MUTE" else "Pad: on")) app.params.pad_mute = !app.params.pad_mute;
        // 自己進化の全体トグル（off で完全な手動シーケンサ。lock していないトラックだけ進化する）
        if (ctx.buttonId(TOGGLE_BASE + 100, if (cmd.evolve) "Evolve: on" else "Evolve: off", .{ .selected = cmd.evolve }).clicked) {
            cmd.evolve = !cmd.evolve;
            edited = true;
        }
        ctx.endBox();

        // DrumMachine grid（行末 Lock = そのトラックを進化から凍結）
        ctx.label("DRUM MACHINE (click cells; Lock=freeze track):");
        drumRow(&ctx, 0, "Kick ", gui.Color.rgba(0xE0, 0x60, 0x50, 0xFF), &cmd.kick.on, &cmd.kick.lock, &edited);
        drumRow(&ctx, 1, "Hat  ", gui.Color.rgba(0x50, 0xC0, 0xD0, 0xFF), &cmd.hat.on, &cmd.hat.lock, &edited);
        drumRow(&ctx, 2, "Clap ", gui.Color.rgba(0xE0, 0xC0, 0x50, 0xFF), &cmd.clap.on, &cmd.clap.lock, &edited);

        // BassMachine（303 レーン: on / pitch / accent / slide）
        ctx.label("BASS MACHINE (303):");
        // on 行
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("On   ");
        {
            var s: u8 = 0;
            while (s < 16) : (s += 1) {
                const on = (cmd.bass.on & bitOf(s)) != 0;
                const col = if (on) gui.Color.rgba(0x60, 0xD0, 0x70, 0xFF) else cellOffColor(s);
                if (ctx.colorSwatchId(BASS_CELL_BASE + 0 * 16 + s, .{ .color = col, .size = CELL }).clicked) {
                    cmd.bass.on ^= bitOf(s);
                    edited = true;
                }
            }
        }
        if (ctx.buttonId(TOGGLE_BASE + 3, if (cmd.bass.lock) "Lock: on" else "Lock: off", .{ .selected = cmd.bass.lock }).clicked) {
            cmd.bass.lock = !cmd.bass.lock;
            edited = true;
        }
        ctx.endBox();
        // pitch 行（クリックで degree を循環）
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("Pitch");
        {
            var s: u8 = 0;
            while (s < 16) : (s += 1) {
                if (ctx.colorSwatchId(BASS_CELL_BASE + 1 * 16 + s, .{ .color = pitchColor(cmd.bass.deg[s]), .size = CELL }).clicked) {
                    const next: i32 = @mod(@as(i32, cmd.bass.deg[s]) + 1, @as(i32, BASS_DEG_TOTAL));
                    cmd.bass.deg[s] = @intCast(next);
                    edited = true;
                }
            }
        }
        ctx.endBox();
        // accent 行
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("Accnt");
        {
            var s: u8 = 0;
            while (s < 16) : (s += 1) {
                const on = (cmd.bass.accent & bitOf(s)) != 0;
                const col = if (on) gui.Color.rgba(0xE0, 0x90, 0x40, 0xFF) else cellOffColor(s);
                if (ctx.colorSwatchId(BASS_CELL_BASE + 2 * 16 + s, .{ .color = col, .size = CELL }).clicked) {
                    cmd.bass.accent ^= bitOf(s);
                    edited = true;
                }
            }
        }
        ctx.endBox();
        // slide 行
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("Slide");
        {
            var s: u8 = 0;
            while (s < 16) : (s += 1) {
                const on = (cmd.bass.slide & bitOf(s)) != 0;
                const col = if (on) gui.Color.rgba(0x60, 0x80, 0xE0, 0xFF) else cellOffColor(s);
                if (ctx.colorSwatchId(BASS_CELL_BASE + 3 * 16 + s, .{ .color = col, .size = CELL }).clicked) {
                    cmd.bass.slide ^= bitOf(s);
                    edited = true;
                }
            }
        }
        ctx.endBox();

        ctx.endBox(); // パネル
        ctx.endFrame();

        // scalar は毎フレーム publish。pattern は編集があったフレームだけ revision++ で publish。
        // pattern_db(Mailbox/triple-buffer) は 1 フレーム最大 1 publish（GUI は ~60fps の frame レート）。
        // RT は毎ブロック(~10ms)で acquire() で最新を latch する。triple-buffer なので consumer が
        // 保持中の slot は後続 publish で書き換わらず torn read が起きない（既存 synth と同方針。TASK-56）。
        publishControls(patch, app.params);
        if (edited) {
            app.pattern_rev += 1;
            cmd.rev = app.pattern_rev;
            patch.controls.pattern_db.publish(cmd);
        }

        @memset(fb.pixels, BG);
        spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, VIS_Y0);
        osc.draw(fb.pixels, fb.width, fb.height, SCOPE_X0, VIS_Y0);
        meter.draw(fb.pixels, fb.width, fb.height, METER_X0, VIS_Y0, METER_W, VIS_H);
        drawVizLabels(fb, spec);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font);

        window.present();
        platform.sleep(16_000_000);
    }

    std.debug.print("apps/modular: done.\n", .{});
}

// ----------------------------------------------------------------------------
// 可視化ラベル（メインスレッド手動描画）
// ----------------------------------------------------------------------------
fn putFb(fb: platform.Framebuffer, x: usize, y: usize, c: u32) void {
    if (x >= fb.width or y >= fb.height) return;
    fb.pixels[y * fb.width + x] = c;
}

const FreqLabel = struct { hz: f32, text: []const u8 };
const FREQ_LABELS = [_]FreqLabel{
    .{ .hz = 100, .text = "100Hz" },
    .{ .hz = 1000, .text = "1kHz" },
    .{ .hz = 10000, .text = "10kHz" },
};

fn drawVizLabels(fb: platform.Framebuffer, spec: *const Spec) void {
    const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
    const clip: gui.Rect = .{ .x = 0, .y = 0, .w = @intCast(fb.width), .h = @intCast(fb.height) };
    const label_col = gui.Color.rgba(0xE0, 0xE0, 0xE0, 0xFF);
    const tick_col: u32 = 0xFFFFFFFF;

    const title_y: i32 = VIS_Y0 - 14;
    gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0, .y = title_y }, "SPECTROGRAM", label_col, clip);
    gui.default_bitmap_font.drawTo(target, .{ .x = SCOPE_X0, .y = title_y }, "SCOPE", label_col, clip);
    gui.default_bitmap_font.drawTo(target, .{ .x = METER_X0 - 4, .y = title_y }, "LVL", label_col, clip);

    const ty_min: i32 = VIS_Y0;
    const ty_max: i32 = VIS_Y0 + VIS_H - 16;
    for (FREQ_LABELS) |fl| {
        const off = spec.rowOffsetForFreq(fl.hz) orelse continue;
        const tick_y = VIS_Y0 + off;
        var tx: usize = SPEC_X0;
        while (tx < SPEC_X0 + 6) : (tx += 1) putFb(fb, tx, tick_y, tick_col);
        const ty = std.math.clamp(@as(i32, @intCast(tick_y)) - 8, ty_min, ty_max);
        gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0 + 8, .y = ty }, fl.text, label_col, clip);
    }
}

// ============================================================================
// ヘッドレス検証 harness の custom probe（TASK-32.3）
// digest は framework 固定 1024B 以内に収める。詳細 pattern(bass_deg 配列)は snapshot 側に出す。
// ============================================================================
fn b01(v: bool) u8 {
    return if (v) @as(u8, 1) else 0;
}

fn modularDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const p = app.patch orelse return std.fmt.bufPrint(buf, "{{\"playing\":false}}", .{}) catch buf[0..0];
    const st = p.snapshotState();
    // 3 ピースに分けて同じ buf へ連結（bufPrint は 1 呼び出し 32 引数上限）。
    const a = std.fmt.bufPrint(buf, "{{\"playing\":true,\"bpm\":{d:.0},\"clock_phase\":{d:.3},\"density\":{d:.3}," ++
        "\"swing\":{d:.3},\"sidechain\":{d:.3},\"master_cutoff\":{d:.0},\"bass_pitch_cv\":{d:.4}," ++
        "\"steps\":{{\"kick\":{d},\"hat\":{d},\"clap\":{d},\"bass\":{d}}}," ++
        "\"active\":{{\"kick\":{},\"hat\":{},\"clap\":{},\"pad\":{}}}," ++
        "\"gains\":{{\"kick\":{d:.3},\"hat\":{d:.3},\"clap\":{d:.3},\"bass\":{d:.3},\"pad\":{d:.3}}}," ++
        "\"muted\":{{\"kick\":{},\"hat\":{},\"clap\":{},\"bass\":{},\"pad\":{}}},", .{
        st.bpm,           st.clock_phase,      st.density,
        st.swing,         st.sidechain_amount, st.master_cutoff, st.bass_pitch_cv,
        st.kick_step,     st.hat_step,         st.clap_step,     st.bass_step,
        st.kick_active,   st.hat_active,       st.clap_active,   st.pad_active,
        st.kick_gain,     st.hat_gain,         st.clap_gain,     st.bass_gain,  st.pad_gain,
        st.kick_muted,    st.hat_muted,        st.clap_muted,    st.bass_muted, st.pad_muted,
    }) catch return buf[0..0];
    const b = std.fmt.bufPrint(buf[a.len..], "\"ph4\":{{\"kick_click\":{d:.3},\"hat_bright\":{d:.3}," ++
        "\"pad_cutoff\":{d:.0},\"pad_warmth\":{d:.3},\"master_drive\":{d:.3}," ++
        "\"pre_clip_peak\":{d:.3},\"clip_rate\":{d:.4}}}," ++
        "\"ambient\":{{\"move\":{d:.3},\"register\":{d},\"root_cv\":{d:.4}}},", .{
        st.kick_click_gain, st.hat_brightness,  st.pad_cutoff, st.pad_warmth,
        st.master_drive,    st.pre_clip_peak,   st.clip_rate,
        st.ambient_move,    st.ambient_register, st.ambient_root_cv,
    }) catch return buf[0..a.len];
    // Ph5 pattern（masks は hex。bass_deg 配列は snapshot 側）。
    const c = std.fmt.bufPrint(buf[a.len + b.len ..], "\"patterns\":{{\"kick\":\"{x:0>4}\",\"hat\":\"{x:0>4}\"," ++
        "\"clap\":\"{x:0>4}\",\"bass_on\":\"{x:0>4}\",\"bass_accent\":\"{x:0>4}\",\"bass_slide\":\"{x:0>4}\"}}," ++
        "\"lock\":[{d},{d},{d},{d}],\"evolve\":{d},\"rev\":{d},\"mut\":{d}}}", .{
        st.kick_on,                 st.hat_on,                  st.clap_on,
        st.bass_on,                 st.bass_accent,             st.bass_slide,
        b01(st.lock[0]),            b01(st.lock[1]),            b01(st.lock[2]),            b01(st.lock[3]),
        b01(st.evolve),             st.pattern_rev,             st.mutation_count,
    }) catch return buf[0 .. a.len + b.len];
    return buf[0 .. a.len + b.len + c.len];
}

fn modularSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const p = app.patch orelse return allocator.dupe(u8, "{\"playing\":false}");
    const st = p.snapshotState();
    // digest（1024B 以内）に bass_deg 配列を足した詳細スナップショット（固定 buf に組み立て→dupe）。
    var dbuf: [1024]u8 = undefined;
    const d = modularDigest(ctx, &dbuf);
    const body = if (d.len > 0 and d[d.len - 1] == '}') d[0 .. d.len - 1] else d; // 末尾 '}' を外す
    var out: [2048]u8 = undefined;
    var off: usize = 0;
    {
        const piece = std.fmt.bufPrint(out[off..], "{s},\"bass_deg\":[", .{body}) catch return allocator.dupe(u8, d);
        off += piece.len;
    }
    for (st.bass_deg, 0..) |dg, i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}{d}", .{ sep, dg }) catch break;
        off += piece.len;
    }
    const tail = std.fmt.bufPrint(out[off..], "]}}", .{}) catch "";
    off += tail.len;
    return allocator.dupe(u8, out[0..off]);
}

// ============================================================================
// ヘッドレス検証 harness の custom action（TASK-65。TASK-62.1 の registerAction を modular が採用。
// pixie(TASK-64)/synth(TASK-65) と同じ「probe(read) に対称な write 口。既存の GUI 編集経路と同じ
// publish 呼び出しをそのまま辿る」構図）。
//
// ホットパス宣言: 全 action の `run()` は「イベント時のみ」（harness `action` コマンド1回につき1回、
// main thread の pollGate 内で実行）。フレーム毎・毎サンプルのいずれでもないため性能規約の適用対象外。
// action が触れる状態伝播は既存の RT-safe cross-thread hand-off をそのまま使うだけで、RT 経路
// （`LofiPatch.render`→graph `processBlock`）へ新たな同期/alloc/lock/panic は一切追加しない:
//   - scalar param / mute: `publishControls`（atomic store。GUI が毎フレーム呼ぶ既存コードと同一）。
//   - pattern 編集(lock/evolve/step/pitch): `patch.snapshotState()` で最新 pattern を読み
//     `stateToCommand` で編集用 base に変換 → 該当 field を書換 → `app.pattern_rev` を1回だけ increment
//     → `patch.controls.pattern_db.publish(cmd)`（triple-buffer Mailbox。GUI の「1 フレームで edited=true
//     のときだけ publish」と全く同じ経路・同じ revision カウンタを共有するため二重採番が起きない）。
//
// パーサは `actions.zig`（std のみ・App/kit/modular 非依存）に切り出し単体テストする。track 名の enum
// 解決は App の具象型を知るこのファイル側で行う（pixie の `ToolKind` 解決と同じ分離方針）。
// ============================================================================

fn actionApp(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

/// `Params` の f32 field へ comptime dispatch で書き込む（`set_param` 汎用 setter）。
fn setParamsF32(p: *Params, name: []const u8, value: f32) error{UnknownParam}!void {
    inline for (@typeInfo(Params).@"struct".fields) |f| {
        if (f.type == f32 and std.mem.eql(u8, f.name, name)) {
            @field(p, f.name) = value;
            return;
        }
    }
    return error.UnknownParam;
}

fn actionSetParam(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const nf = try actions.parseNameF32(args);
    try setParamsF32(&app.params, nf.name, nf.value);
    publishControls(patch, app.params);
    return "ok";
}

const MuteTrack = enum { kick, hat, clap, bass, pad };

fn actionSetMute(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const p = try actions.parseNameBool(args);
    const track = std.meta.stringToEnum(MuteTrack, p.name) orelse return error.UnknownTrack;
    switch (track) {
        .kick => app.params.kick_mute = p.on,
        .hat => app.params.hat_mute = p.on,
        .clap => app.params.clap_mute = p.on,
        .bass => app.params.bass_mute = p.on,
        .pad => app.params.pad_mute = p.on,
    }
    publishControls(patch, app.params);
    return "ok";
}

const LockTrack = enum { kick, hat, clap, bass };

fn actionSetLock(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const p = try actions.parseNameBool(args);
    const track = std.meta.stringToEnum(LockTrack, p.name) orelse return error.UnknownTrack;
    var cmd = stateToCommand(patch.snapshotState());
    switch (track) {
        .kick => cmd.kick.lock = p.on,
        .hat => cmd.hat.lock = p.on,
        .clap => cmd.clap.lock = p.on,
        .bass => cmd.bass.lock = p.on,
    }
    app.pattern_rev += 1;
    cmd.rev = app.pattern_rev;
    patch.controls.pattern_db.publish(cmd);
    return "ok";
}

fn actionSetEvolve(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const on = try actions.parseBool01(args);
    var cmd = stateToCommand(patch.snapshotState());
    cmd.evolve = on;
    app.pattern_rev += 1;
    cmd.rev = app.pattern_rev;
    patch.controls.pattern_db.publish(cmd);
    return "ok";
}

const StepTarget = enum { kick, hat, clap, bass_on, bass_accent, bass_slide };

fn actionToggleStep(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const p = try actions.parseNameU8(args);
    const target = std.meta.stringToEnum(StepTarget, p.name) orelse return error.UnknownTrack;
    if (p.value >= 16) return error.StepOutOfRange;
    var cmd = stateToCommand(patch.snapshotState());
    const mask = bitOf(p.value);
    switch (target) {
        .kick => cmd.kick.on ^= mask,
        .hat => cmd.hat.on ^= mask,
        .clap => cmd.clap.on ^= mask,
        .bass_on => cmd.bass.on ^= mask,
        .bass_accent => cmd.bass.accent ^= mask,
        .bass_slide => cmd.bass.slide ^= mask,
    }
    app.pattern_rev += 1;
    cmd.rev = app.pattern_rev;
    patch.controls.pattern_db.publish(cmd);
    return "ok";
}

fn actionSetPitch(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const p = try actions.parseTwoU8(args); // a=step(0..15) b=deg(0..BASS_DEG_TOTAL-1)
    if (p.a >= 16) return error.StepOutOfRange;
    if (p.b >= BASS_DEG_TOTAL) return error.DegreeOutOfRange;
    var cmd = stateToCommand(patch.snapshotState());
    cmd.bass.deg[p.a] = @intCast(p.b);
    app.pattern_rev += 1;
    cmd.rev = app.pattern_rev;
    patch.controls.pattern_db.publish(cmd);
    return "ok";
}

// ============================================================================
// save_pattern / load_pattern（TASK-65 serialize。probe `modular` と対称の永続化口）。
//
// ホットパス宣言: save/load はイベント時のみ（action 1回につき1回。std.Io のブロッキング file I/O は
// main thread の pollGate 内で完結する）。RT 経路（LofiPatch.render→graph processBlock）には
// 一切触れない。保存対象は App.params（scalar）+ 現在の grid/303 pattern（PatternCommand の中身）。
// load は既存の pattern 編集 action と同じ経路（publishControls / pattern_rev++ → pattern_db.publish）
// をそのまま辿るため revision の二重採番は起きない。
// ============================================================================

/// 現在の `PatternCommand` を `pattern_io.PatternPayload`（app 非依存の plain struct）へ写す。
fn patternToPayload(cmd: PatternCommand) pattern_io.PatternPayload {
    return .{
        .evolve = cmd.evolve,
        .kick_on = cmd.kick.on,
        .kick_lock = cmd.kick.lock,
        .hat_on = cmd.hat.on,
        .hat_lock = cmd.hat.lock,
        .clap_on = cmd.clap.on,
        .clap_lock = cmd.clap.lock,
        .bass_on = cmd.bass.on,
        .bass_accent = cmd.bass.accent,
        .bass_slide = cmd.bass.slide,
        .bass_lock = cmd.bass.lock,
        .bass_deg = cmd.bass.deg,
    };
}

/// `pattern_io.PatternPayload` を `rev` 付きで `PatternCommand` へ復元する（rev は payload に
/// 含めず、他の pattern 編集 action と同じ「app.pattern_rev を1回 increment」で払い出す）。
fn payloadToPatternCommand(rev: u32, p: pattern_io.PatternPayload) PatternCommand {
    return .{
        .rev = rev,
        .evolve = p.evolve,
        .kick = .{ .on = p.kick_on, .lock = p.kick_lock },
        .hat = .{ .on = p.hat_on, .lock = p.hat_lock },
        .clap = .{ .on = p.clap_on, .lock = p.clap_lock },
        .bass = .{ .on = p.bass_on, .accent = p.bass_accent, .slide = p.bass_slide, .deg = p.bass_deg, .lock = p.bass_lock },
    };
}

fn actionSavePattern(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const path = try actions.parsePath(args);
    const cmd = stateToCommand(patch.snapshotState());
    try pattern_io.save(app.io, path, Params, app.params, patternToPayload(cmd), std.heap.c_allocator);
    return "ok";
}

fn actionLoadPattern(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const path = try actions.parsePath(args);
    const loaded = try pattern_io.load(app.io, std.heap.c_allocator, path, Params);
    app.params = loaded.params;
    publishControls(patch, app.params);
    app.pattern_rev += 1;
    const cmd = payloadToPatternCommand(app.pattern_rev, loaded.pattern);
    patch.controls.pattern_db.publish(cmd);
    return "ok";
}

/// 8 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness 無効時は
/// `registerAction` 自体が no-op なので通常実行に影響しない）。
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "set_param", .ctx = app, .run = actionSetParam });
    platform.registerAction(.{ .name = "set_mute", .ctx = app, .run = actionSetMute });
    platform.registerAction(.{ .name = "set_lock", .ctx = app, .run = actionSetLock });
    platform.registerAction(.{ .name = "set_evolve", .ctx = app, .run = actionSetEvolve });
    platform.registerAction(.{ .name = "toggle_step", .ctx = app, .run = actionToggleStep });
    platform.registerAction(.{ .name = "set_pitch", .ctx = app, .run = actionSetPitch });
    platform.registerAction(.{ .name = "save_pattern", .ctx = app, .run = actionSavePattern });
    platform.registerAction(.{ .name = "load_pattern", .ctx = app, .run = actionLoadPattern });
}
