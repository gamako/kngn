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
const stepgrid = gui.stepgrid;
const recipe = kit.recipe;
const spectrogram = @import("spectrogram");
const scope = @import("scope");
const patchmod = @import("patch.zig");
const LofiPatch = patchmod.LofiPatch;
const PatternCommand = patchmod.PatternCommand;
const PatchState = patchmod.PatchState;
const actions = @import("actions.zig");
const pattern_io = @import("pattern_io.zig");
const project_io = @import("project_io.zig");
const wav = @import("wav.zig");
const seedmod = @import("seed.zig");
const SongData = patchmod.SongData;
const Chain = patchmod.Chain;

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
    /// device config の整数 sample_rate（`action render` の WAV ヘッダと offline patch の単一ソース。TASK-86）。
    sample_rate: u32 = 48000,
    /// CommandLog + Executor（TASK-62.5.7: 記録のみ。undo/tx/probe 統合なし）。
    cmd_log: platform.command.CommandLog = .{},
    cmd_exec: platform.command.Executor = undefined,
    /// recipe_replay 実行中フラグ（入れ子拒否用。TASK-62.5.8）。
    recipe_replaying: bool = false,
    /// TASK-93 mini-notation 用。`action seed` で同期する app 所有 base seed（RT base_seed は
    /// bar 進行依存で replay 決定性が壊れるため読まない）。初期値 = DEFAULT_BASE_SEED。
    notation_seed: u64 = seedmod.DEFAULT_BASE_SEED,
    /// 評価ごと ++。rng_seed / alt_index の両方に使い、レシピ replay で counter 順が一致すれば決定的。
    /// `recipe_replay` 冒頭で 0 にリセットする。
    notation_counter: u32 = 0,
    /// bar 境界前の連続 `action pattern` 用。直前に publish した quantize cmd（後続の base）。
    last_quantized_cmd: ?PatternCommand = null,
    /// TASK-91: SongData 編集用（RT へは rev++ → song_db.publish）。
    song: SongData = .{},
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
const LOCK_COL = gui.Color.rgba(0xC0, 0x60, 0x60, 0xFF);
const DIM = gui.Color.rgba(0x2A, 0x2E, 0x36, 0xFF);
const DIM_BEAT = gui.Color.rgba(0x3A, 0x40, 0x4A, 0xFF);
const KICK_ON = gui.Color.rgba(0xE0, 0x60, 0x50, 0xFF);
const HAT_ON = gui.Color.rgba(0x50, 0xC0, 0xD0, 0xFF);
const CLAP_ON = gui.Color.rgba(0xE0, 0xC0, 0x50, 0xFF);
const BASS_ON = gui.Color.rgba(0x60, 0xD0, 0x70, 0xFF);
const ACCENT_ON = gui.Color.rgba(0xE0, 0x90, 0x40, 0xFF);
const SLIDE_ON = gui.Color.rgba(0x60, 0x80, 0xE0, 0xFF);

const DRUM_CELL_BASE: u64 = 0x8000;
const BASS_CELL_BASE: u64 = 0x8200;
const TOGGLE_BASE: u64 = 0x8400;

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
    if (stepgrid.widgetRow(ctx, .{
        .id_base = DRUM_CELL_BASE + track * 16,
        .mask = on_mask.*,
        .on_color = on_color,
        .off_color = DIM,
        .off_beat_color = DIM_BEAT,
    })) |cell| {
        on_mask.* ^= bitOf(cell.step);
        edited.* = true;
    }
    if (ctx.buttonId(TOGGLE_BASE + track, if (lock.*) "Lock: on" else "Lock: off", .{ .selected = lock.* }).clicked) {
        lock.* = !lock.*;
        edited.* = true;
    }
    ctx.endBox();
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

    const sr_u32 = device.config().sample_rate;
    app.sample_rate = sr_u32;
    const sr: f32 = @floatFromInt(sr_u32);
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
    // command model（TASK-62.5.7）: 記録のみ。pixie 62.5.3 の最小版（undo/tx なし）。
    app.cmd_exec = platform.command.Executor.init(.{ .ctx = app, .run = dispatchModularAction });
    app.cmd_exec.log = &app.cmd_log;
    platform.setCommandExecutor(&app.cmd_exec);
    // ヘッドレス検証 harness の custom action を登録（harness 無効時は no-op。TASK-65）。
    registerActions(app);
    registerStateSync(app);

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
        drumRow(&ctx, 0, "Kick ", KICK_ON, &cmd.kick.on, &cmd.kick.lock, &edited);
        drumRow(&ctx, 1, "Hat  ", HAT_ON, &cmd.hat.on, &cmd.hat.lock, &edited);
        drumRow(&ctx, 2, "Clap ", CLAP_ON, &cmd.clap.on, &cmd.clap.lock, &edited);

        // BassMachine（303 レーン: on / pitch / accent / slide）
        ctx.label("BASS MACHINE (303):");
        // on 行
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("On   ");
        if (stepgrid.widgetRow(&ctx, .{
            .id_base = BASS_CELL_BASE + 0 * 16,
            .mask = cmd.bass.on,
            .on_color = BASS_ON,
            .off_color = DIM,
            .off_beat_color = DIM_BEAT,
        })) |cell| {
            cmd.bass.on ^= bitOf(cell.step);
            edited = true;
        }
        if (ctx.buttonId(TOGGLE_BASE + 3, if (cmd.bass.lock) "Lock: on" else "Lock: off", .{ .selected = cmd.bass.lock }).clicked) {
            cmd.bass.lock = !cmd.bass.lock;
            edited = true;
        }
        ctx.endBox();
        // pitch 行（クリックで degree を循環）
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("Pitch");
        if (stepgrid.widgetRow(&ctx, .{
            .id_base = BASS_CELL_BASE + 1 * 16,
            .pitch = .{ .degrees = cmd.bass.deg[0..], .degree_count = BASS_DEG_TOTAL, .style = .cells },
            .off_color = DIM,
            .off_beat_color = DIM_BEAT,
        })) |cell| {
            const next: i32 = @mod(@as(i32, cmd.bass.deg[cell.step]) + 1, @as(i32, BASS_DEG_TOTAL));
            cmd.bass.deg[cell.step] = @intCast(next);
            edited = true;
        }
        ctx.endBox();
        // accent 行
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("Accnt");
        if (stepgrid.widgetRow(&ctx, .{
            .id_base = BASS_CELL_BASE + 2 * 16,
            .mask = cmd.bass.accent,
            .on_color = ACCENT_ON,
            .off_color = DIM,
            .off_beat_color = DIM_BEAT,
        })) |cell| {
            cmd.bass.accent ^= bitOf(cell.step);
            edited = true;
        }
        ctx.endBox();
        // slide 行
        ctx.beginBox(.{ .direction = .row, .gap = 2, .align_cross = .center });
        ctx.label("Slide");
        if (stepgrid.widgetRow(&ctx, .{
            .id_base = BASS_CELL_BASE + 3 * 16,
            .mask = cmd.bass.slide,
            .on_color = SLIDE_ON,
            .off_color = DIM,
            .off_beat_color = DIM_BEAT,
        })) |cell| {
            cmd.bass.slide ^= bitOf(cell.step);
            edited = true;
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
        st.swing,         st.sidechain_amount, st.master_cutoff,
        st.bass_pitch_cv, st.kick_step,        st.hat_step,
        st.clap_step,     st.bass_step,        st.kick_active,
        st.hat_active,    st.clap_active,      st.pad_active,
        st.kick_gain,     st.hat_gain,         st.clap_gain,
        st.bass_gain,     st.pad_gain,         st.kick_muted,
        st.hat_muted,     st.clap_muted,       st.bass_muted,
        st.pad_muted,
    }) catch return buf[0..0];
    const b = std.fmt.bufPrint(buf[a.len..], "\"ph4\":{{\"kick_click\":{d:.3},\"hat_bright\":{d:.3}," ++
        "\"pad_cutoff\":{d:.0},\"pad_warmth\":{d:.3},\"master_drive\":{d:.3}," ++
        "\"pre_clip_peak\":{d:.3},\"clip_rate\":{d:.4}}}," ++
        "\"ambient\":{{\"move\":{d:.3},\"register\":{d},\"root_cv\":{d:.4}}},", .{
        st.kick_click_gain,  st.hat_brightness,  st.pad_cutoff, st.pad_warmth,
        st.master_drive,     st.pre_clip_peak,   st.clip_rate,  st.ambient_move,
        st.ambient_register, st.ambient_root_cv,
    }) catch return buf[0..a.len];
    // Ph5 pattern（masks は hex。bass_deg 配列は snapshot 側）+ TASK-91 song 要約。
    // 末尾は 1 つの `}` で JSON を閉じる（1024B 注意）。
    const c = std.fmt.bufPrint(buf[a.len + b.len ..], "\"patterns\":{{\"kick\":\"{x:0>4}\",\"hat\":\"{x:0>4}\"," ++
        "\"clap\":\"{x:0>4}\",\"bass_on\":\"{x:0>4}\",\"bass_accent\":\"{x:0>4}\",\"bass_slide\":\"{x:0>4}\"}}," ++
        "\"lock\":[{d},{d},{d},{d}],\"evolve\":{d},\"rev\":{d},\"mut\":{d},\"seed\":{d}," ++
        "\"song\":{{\"playing\":{d},\"row\":{d},\"bar\":{d},\"rows\":{d}}}}}", .{
        st.kick_on,        st.hat_on,          st.clap_on,
        st.bass_on,        st.bass_accent,     st.bass_slide,
        b01(st.lock[0]),   b01(st.lock[1]),    b01(st.lock[2]),
        b01(st.lock[3]),   b01(st.evolve),     st.pattern_rev,
        st.mutation_count, st.base_seed,       b01(st.song_playing),
        st.song_row,       st.song_bar_in_row, st.song_rows,
    }) catch return buf[0 .. a.len + b.len];
    return buf[0 .. a.len + b.len + c.len];
}

fn modularSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const p = app.patch orelse return allocator.dupe(u8, "{\"playing\":false}");
    const st = p.snapshotState();
    // digest（1024B 以内）に bass_deg 配列 + song 詳細を足した詳細スナップショット（固定 buf に組み立て→dupe）。
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
    // TASK-91: song 詳細（rows 要約 + chain lens + loop）
    {
        const piece = std.fmt.bufPrint(out[off..], "],\"song_detail\":{{\"loop\":{d},\"rev\":{d},\"rows\":[", .{
            b01(st.song_loop),
            st.song_rev,
        }) catch {
            const tail = std.fmt.bufPrint(out[off..], "]}}", .{}) catch "";
            off += tail.len;
            return allocator.dupe(u8, out[0..off]);
        };
        off += piece.len;
    }
    const song = p.song;
    const n_rows: usize = @min(@as(usize, st.song_rows), 8); // 要約: 先頭 8 row
    var ri: usize = 0;
    while (ri < n_rows) : (ri += 1) {
        const row = song.rows[ri];
        const sep: []const u8 = if (ri == 0) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}[{d},{d},{d},{d}]", .{
            sep, row.kick, row.hat, row.clap, row.bass,
        }) catch break;
        off += piece.len;
    }
    {
        const piece = std.fmt.bufPrint(out[off..], "],\"chain_lens\":[", .{}) catch "";
        off += piece.len;
    }
    var ci: usize = 0;
    while (ci < 8) : (ci += 1) {
        const sep: []const u8 = if (ci == 0) "" else ",";
        const piece = std.fmt.bufPrint(out[off..], "{s}{d}", .{ sep, song.chains[ci].len }) catch break;
        off += piece.len;
    }
    const tail = std.fmt.bufPrint(out[off..], "]}}}}", .{}) catch "";
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

/// `action seed <n>`: main thread で parse → lock-free publish → 次 bar 境界で RT が適用（TASK-62.5.7）。
/// TASK-93: app.notation_seed も同期（mini-notation の `?` / 交代が seed 規約と整合する）。
fn actionSeed(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const n = try actions.parseU64(args);
    app.notation_seed = n;
    patch.requestSeed(n);
    return "ok";
}

// ============================================================================
// TASK-91: Song/Chain/Phrase actions（recorded = seed+recipe 決定性に整合）
// 編集は app.song を書き換え → rev++ → song_db.publish（宣言的全置換粒度 = SongData 全体）。
// ============================================================================

fn publishSong(app: *App, patch: *LofiPatch) void {
    app.song.rev +%= 1;
    patch.controls.song_db.publish(app.song);
}

/// `phrase_capture <idx>`: 現在パターンを drum pool[idx]×3 + bass pool[idx] へ取り込み。
fn actionPhraseCapture(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const idx = actions.parseU8(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: phrase_capture <idx 0..31>");
        return error.BadArgs;
    };
    // bass pool 上限 32 に合わせる（4 track 同 idx のため）
    if (idx >= patchmod.MAX_BASS_PHRASES) {
        platform.setActionErrorDetail("index_out_of_range", "phrase idx must be 0..31");
        return error.IndexOutOfRange;
    }
    const st = patch.snapshotState();
    app.song.phrases_kick[idx] = st.kick_on;
    app.song.phrases_hat[idx] = st.hat_on;
    app.song.phrases_clap[idx] = st.clap_on;
    app.song.phrases_bass[idx] = .{
        .on = st.bass_on,
        .accent = st.bass_accent,
        .slide = st.bass_slide,
        .deg = st.bass_deg,
    };
    publishSong(app, patch);
    return "ok";
}

/// `chain_set <chain_idx> <phrase_idx...>`（1..16）。
fn actionChainSet(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const parsed = actions.parseChainSet(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: chain_set <chain_idx> <phrase_idx...>");
        return error.BadArgs;
    };
    if (parsed.chain_idx >= patchmod.MAX_CHAINS) {
        platform.setActionErrorDetail("index_out_of_range", "chain_idx must be 0..31");
        return error.IndexOutOfRange;
    }
    var i: u8 = 0;
    while (i < parsed.len) : (i += 1) {
        // drum pool 64 / bass 32。chain は共有なので 0..63 を許容（bass 解決時 OOB は RT で現行維持）
        if (parsed.phrases[i] >= patchmod.MAX_DRUM_PHRASES) {
            platform.setActionErrorDetail("index_out_of_range", "phrase_idx must be 0..63");
            return error.IndexOutOfRange;
        }
    }
    var ch: Chain = .{};
    ch.len = parsed.len;
    @memcpy(ch.entries[0..parsed.len], parsed.phrases[0..parsed.len]);
    app.song.chains[parsed.chain_idx] = ch;
    publishSong(app, patch);
    return "ok";
}

/// `song_row <row_idx> <kick_chain> <hat_chain> <clap_chain> <bass_chain>`。
fn actionSongRow(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const parsed = actions.parseSongRow(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_row <row> <kick> <hat> <clap> <bass>");
        return error.BadArgs;
    };
    if (parsed.row_idx >= patchmod.MAX_SONG_ROWS) {
        platform.setActionErrorDetail("index_out_of_range", "row_idx must be 0..63");
        return error.IndexOutOfRange;
    }
    if (parsed.kick >= patchmod.MAX_CHAINS or parsed.hat >= patchmod.MAX_CHAINS or
        parsed.clap >= patchmod.MAX_CHAINS or parsed.bass >= patchmod.MAX_CHAINS)
    {
        platform.setActionErrorDetail("index_out_of_range", "chain index must be 0..31");
        return error.IndexOutOfRange;
    }
    app.song.rows[parsed.row_idx] = .{
        .kick = parsed.kick,
        .hat = parsed.hat,
        .clap = parsed.clap,
        .bass = parsed.bass,
    };
    publishSong(app, patch);
    return "ok";
}

/// `song_len <n>`（0..64）。
fn actionSongLen(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const n = actions.parseU8(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_len <0..64>");
        return error.BadArgs;
    };
    if (n > patchmod.MAX_SONG_ROWS) {
        platform.setActionErrorDetail("index_out_of_range", "song_len must be 0..64");
        return error.IndexOutOfRange;
    }
    app.song.row_count = n;
    publishSong(app, patch);
    return "ok";
}

/// `song_loop <0|1>`。
fn actionSongLoop(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const on = actions.parseBool01(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_loop <0|1>");
        return error.BadArgs;
    };
    app.song.loop = on;
    publishSong(app, patch);
    return "ok";
}

/// `song_play <0|1>`。開始時は RT が position リセット（applyControls の rising edge）。
fn actionSongPlay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const on = actions.parseBool01(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_play <0|1>");
        return error.BadArgs;
    };
    // SongData 最新を載せてから play（編集後の unpublish 漏れ防止）
    publishSong(app, patch);
    patch.controls.song_playing.store(@intFromBool(on), .release);
    return "ok";
}

/// `song_goto <row>`。
fn actionSongGoto(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const row = actions.parseU8(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: song_goto <row 0..63>");
        return error.BadArgs;
    };
    if (row >= patchmod.MAX_SONG_ROWS) {
        platform.setActionErrorDetail("index_out_of_range", "row must be 0..63");
        return error.IndexOutOfRange;
    }
    patch.controls.song_goto_row.store(row, .release);
    _ = patch.controls.song_goto_gen.fetchAdd(1, .release);
    return "ok";
}

fn songToPayload(s: SongData) project_io.SongPayload {
    var out: project_io.SongPayload = .{};
    out.phrases_kick = s.phrases_kick;
    out.phrases_hat = s.phrases_hat;
    out.phrases_clap = s.phrases_clap;
    for (s.phrases_bass, 0..) |bp, i| {
        out.phrases_bass[i] = .{ .on = bp.on, .accent = bp.accent, .slide = bp.slide, .deg = bp.deg };
    }
    for (s.chains, 0..) |ch, i| {
        out.chains[i] = .{ .entries = ch.entries, .len = ch.len };
    }
    for (s.rows, 0..) |row, i| {
        out.rows[i] = .{ .kick = row.kick, .hat = row.hat, .clap = row.clap, .bass = row.bass };
    }
    out.row_count = s.row_count;
    out.loop = s.loop;
    return out;
}

fn payloadToSong(rev: u32, p: project_io.SongPayload) SongData {
    var out: SongData = .{};
    out.rev = rev;
    out.phrases_kick = p.phrases_kick;
    out.phrases_hat = p.phrases_hat;
    out.phrases_clap = p.phrases_clap;
    for (p.phrases_bass, 0..) |bp, i| {
        out.phrases_bass[i] = .{ .on = bp.on, .accent = bp.accent, .slide = bp.slide, .deg = bp.deg };
    }
    for (p.chains, 0..) |ch, i| {
        out.chains[i] = .{ .entries = ch.entries, .len = ch.len };
    }
    for (p.rows, 0..) |row, i| {
        out.rows[i] = .{ .kick = row.kick, .hat = row.hat, .clap = row.clap, .bass = row.bass };
    }
    out.row_count = p.row_count;
    out.loop = p.loop;
    return out;
}

/// `save_project <path>`: MPRJ（params+pattern+seed+song）。local_only・非記録。
fn actionSaveProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const path = try actions.parsePath(args);
    const cmd = stateToCommand(patch.snapshotState());
    const st = patch.snapshotState();
    const seed = project_io.SeedPayload{
        .base_seed = st.base_seed,
        .notation_seed = app.notation_seed,
        .notation_counter = app.notation_counter,
    };
    try project_io.save(
        app.io,
        path,
        Params,
        app.params,
        patternToPayload(cmd),
        seed,
        songToPayload(app.song),
        std.heap.c_allocator,
    );
    return "ok";
}

/// `load_project <path>`: SongData publish + params publish + seed 復元。local_only・非記録。
fn actionLoadProject(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const path = try actions.parsePath(args);
    const loaded = project_io.load(app.io, std.heap.c_allocator, path, Params) catch |err| {
        if (err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use save_project first");
        }
        return err;
    };
    app.params = loaded.params;
    publishControls(patch, app.params);
    app.pattern_rev += 1;
    const cmd = payloadToPatternCommand(app.pattern_rev, loaded.pattern);
    patch.controls.pattern_db.publish(cmd);
    app.song = payloadToSong(app.song.rev +% 1, loaded.song);
    patch.controls.song_db.publish(app.song);
    app.notation_seed = loaded.seed.notation_seed;
    app.notation_counter = loaded.seed.notation_counter;
    patch.requestSeed(loaded.seed.base_seed);
    return "ok";
}

/// `action render <path> <seconds>`: offline LofiPatch で master を PCM16 WAV に書き出す（TASK-86）。
///
/// ホットパス宣言: イベント時・main thread のみ。live patch の RT 経路には触らない。
/// offline は完全別インスタンス。複製は seed + 公開済み編集状態（params + snapshot pattern）。
/// live の bar 途中の変異位置（クロック位相・step）は複製しない（完全再現は seed+recipe）。
/// レンダー中 main thread がブロックし UI が止まるのは MVP 割り切り。
fn actionRender(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const live = app.patch orelse return error.NotReady;

    const parsed = actions.parseRender(args) catch {
        platform.setActionErrorDetail("bad_args", "usage: render <path> <seconds 1..600>");
        return error.BadArgs;
    };

    const sr_u32 = app.sample_rate;
    const sr_f32: f32 = @floatFromInt(sr_u32);
    // u64 で秒×sr を計算し RIFF u32 制約を先に検査（seconds<=600 では通常到達しない防御）。
    const total_frames_u64: u64 = @as(u64, parsed.seconds) * @as(u64, sr_u32);
    const data_size_u64: u64 = total_frames_u64 * 2 * 2; // stereo PCM16
    if (total_frames_u64 > std.math.maxInt(u32) or 36 + data_size_u64 > std.math.maxInt(u32)) {
        platform.setActionErrorDetail("bad_args", "output too long for RIFF");
        return error.TooLong;
    }
    const total_frames: u32 = @intCast(total_frames_u64);
    const chunk: u32 = 4800;
    const channels: u32 = 2;

    const gpa = std.heap.c_allocator;
    const offline = LofiPatch.create(gpa, sr_f32) catch |err| {
        platform.setActionErrorDetail("create_failed", "offline patch create failed");
        return err;
    };
    defer offline.destroy();

    // live.base_seed は digest と同じ best-effort torn read（新規同期を足さない）。
    offline.resetWithSeed(live.base_seed);
    publishControls(offline, app.params);
    // snapshot pattern を offline に載せ、rev をずらして必ず apply させる。
    var cmd = stateToCommand(live.snapshotState());
    cmd.rev = offline.applied_rev +% 1;
    offline.controls.pattern_db.publish(cmd);

    var file = std.Io.Dir.cwd().createFile(app.io, parsed.path, .{}) catch |err| {
        platform.setActionErrorDetail("write_failed", "cannot create output path");
        return err;
    };
    defer file.close(app.io); // File.close は void（error union ではない）

    var wbuf: [8192]u8 = undefined;
    var fwriter = file.writerStreaming(app.io, &wbuf);
    var wav_w = wav.WavWriter.init(&fwriter.interface, channels, sr_u32, total_frames) catch |err| {
        if (err == error.TooLong) {
            platform.setActionErrorDetail("bad_args", "output too long for RIFF");
        } else {
            platform.setActionErrorDetail("write_failed", "wav header write failed");
        }
        return err;
    };

    const audio_buf = gpa.alloc(f32, chunk * channels) catch |err| {
        platform.setActionErrorDetail("write_failed", "render buffer alloc failed");
        return err;
    };
    defer gpa.free(audio_buf);

    var rendered: u32 = 0;
    while (rendered < total_frames) {
        const n = @min(chunk, total_frames - rendered);
        offline.render(audio_buf, n, channels);
        wav_w.writeChunk(audio_buf[0 .. n * channels]) catch |err| {
            platform.setActionErrorDetail("write_failed", "wav chunk write failed");
            return err;
        };
        rendered += n;
    }
    wav_w.finish() catch |err| {
        platform.setActionErrorDetail("write_failed", "wav finish failed");
        return err;
    };

    return std.fmt.bufPrint(buf, "ok path={s} seconds={d} sr={d}", .{ parsed.path, parsed.seconds, sr_u32 }) catch "ok";
}

// ============================================================================
// TASK-93: `action pattern <track> <notation>`（mini-notation → pattern_db、小節境界適用）
//
// ホットパス宣言: parse/eval は action 実行時（main thread・イベント時）のみ。RT へは評価済み
// PatternCommand（quantize_bar=true）を publish するだけ。RT 追加分は patch.zig の bar 境界
// 固定長コピー（alloc/lock なし）。
// ============================================================================

const PatternTrack = enum { kick, hat, clap, bass };

fn actionPattern(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const pa = actions.parsePatternArgs(args) catch {
        platform.setActionErrorDetail("invalid_notation", "usage: pattern <kick|hat|clap|bass> <notation>");
        return error.InvalidNotation;
    };
    const track = std.meta.stringToEnum(PatternTrack, pa.track) orelse {
        platform.setActionErrorDetail("unknown_track", "track must be kick|hat|clap|bass");
        return error.UnknownTrack;
    };
    const ast = actions.parseNotation(pa.notation) catch {
        platform.setActionErrorDetail("invalid_notation", "check mini-notation syntax");
        return error.InvalidNotation;
    };
    // rng_seed = splitmix64(notation_seed ^ counter)、alt_index = counter。評価後に ++。
    const alt_index = app.notation_counter;
    const rng_seed = seedmod.splitmix64(app.notation_seed ^ @as(u64, alt_index));
    app.notation_counter +%= 1;
    const result = actions.evalNotation(ast, rng_seed, alt_index);

    // P1-3: bar 待ち中（または publish 済みで RT 未 acquire）は last_quantized_cmd を base にし、
    // 連続 pattern で先行 track を潰さない。
    const st = patch.snapshotState();
    var cmd = stateToCommand(st);
    if (app.last_quantized_cmd) |lq| {
        // 我々の最新 quantize がまだ bar 反映前: bar_pending、または applied_rev 未到達
        if (lq.rev == app.pattern_rev and (st.bar_pending or st.pattern_rev != lq.rev)) {
            cmd = lq;
        }
    }
    switch (track) {
        .kick => cmd.kick.on = result.on,
        .hat => cmd.hat.on = result.on,
        .clap => cmd.clap.on = result.on,
        .bass => {
            // 宣言的全置換: on は全置換、deg は deg_set の step のみ上書き（accent/slide は維持）
            cmd.bass.on = result.on;
            var s: u8 = 0;
            while (s < 16) : (s += 1) {
                const m = bitOf(s);
                if (result.deg_set & m != 0) {
                    cmd.bass.deg[s] = result.deg[s];
                }
            }
        },
    }
    // lock されていても明示編集は通す（GUI toggle_step と同挙動）
    cmd.quantize_bar = true;
    app.pattern_rev += 1;
    cmd.rev = app.pattern_rev;
    app.last_quantized_cmd = cmd;
    patch.controls.pattern_db.publish(cmd);
    return "ok";
}

/// CommandLog の kind=normal を seq 順で Entry 化（TASK-62.5.8）。name/args は log 借用。
fn recipeEntriesFromLog(log: *const platform.command.CommandLog, gpa: std.mem.Allocator) ![]recipe.Entry {
    var views_buf: [platform.command.MAX_CMD_LOG]recipe.RecordView = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < log.filled) : (i += 1) {
        const rec = log.recordAt(i);
        views_buf[n] = .{
            .is_normal = rec.kind == .normal,
            .name = rec.name(),
            .args = rec.args(),
        };
        n += 1;
    }
    return recipe.collectNormalEntries(gpa, views_buf[0..n]);
}

/// `recipe_save <path>`: CommandLog → recipe（app_name="modular"）。記録しない。
fn actionRecipeSave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    const path = try actions.parsePath(args);
    const entries = try recipeEntriesFromLog(&app.cmd_log, gpa);
    defer gpa.free(entries);
    try recipe.save(app.io, path, .{ .app_name = "modular" }, entries, gpa);
    return "ok";
}

/// `recipe_replay <path>`: load → app_name 検証 → routeLocalAction 逐次適用。入れ子拒否。
/// TASK-93: notation_counter を 0 から再評価（seed+pattern 列の決定性）。
fn actionRecipeReplay(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    const app = actionApp(ctx);
    const gpa = std.heap.c_allocator;
    recipe.checkNotReplaying(app.recipe_replaying) catch {
        platform.setActionErrorDetail("nested_replay", "wait for current recipe_replay to finish");
        return error.NestedReplay;
    };
    // mini-notation の `?` / `<a b>` を recipe 先頭から決定的に再評価する。
    app.notation_counter = 0;
    const path = try actions.parsePath(args);
    var loaded = recipe.load(app.io, gpa, path) catch |err| {
        if (err == error.FileNotFound) {
            platform.setActionErrorDetail("file_not_found", "check path or use recipe_save first");
        }
        return err;
    };
    defer loaded.deinit();

    recipe.checkAppName(loaded.header.app_name, "modular") catch {
        platform.setActionErrorDetail("app_mismatch", "open with the correct app");
        return error.AppMismatch;
    };

    app.recipe_replaying = true;
    defer app.recipe_replaying = false;

    for (loaded.entries, 0..) |entry, idx| {
        _ = platform.routeAction(entry.name, entry.args, buf) catch |err| {
            if (err == error.NestedReplay) return err;
            var code_buf: [32]u8 = undefined;
            const code = std.fmt.bufPrint(&code_buf, "replay_failed_at_{d}", .{idx + 1}) catch "replay_failed";
            var next_buf: [200]u8 = undefined;
            const next = std.fmt.bufPrint(&next_buf, "fix entry {d} ({s}) or preceding state", .{ idx + 1, entry.name }) catch "fix recipe entry";
            platform.setActionErrorDetail(code, next);
            return error.ReplayFailed;
        };
    }
    return "ok";
}

// ============================================================================
// command model 統合（TASK-62.5.7: 記録のみ。pixie 62.5.3 の最小版）
//
// App が CommandLog + Executor を所有し、registerAction 経由の harness/copilot action を
// executeAction(actor=.local_agent) で dispatch + 記録する。undo/transaction/probe 統合はしない。
// ============================================================================

const ActionEntry = struct {
    name: []const u8,
    run: *const fn (ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8,
};

const MODULAR_ACTIONS = [_]ActionEntry{
    .{ .name = "set_param", .run = actionSetParam },
    .{ .name = "set_mute", .run = actionSetMute },
    .{ .name = "set_lock", .run = actionSetLock },
    .{ .name = "set_evolve", .run = actionSetEvolve },
    .{ .name = "toggle_step", .run = actionToggleStep },
    .{ .name = "set_pitch", .run = actionSetPitch },
    .{ .name = "save_pattern", .run = actionSavePattern },
    .{ .name = "load_pattern", .run = actionLoadPattern },
    .{ .name = "seed", .run = actionSeed },
    .{ .name = "pattern", .run = actionPattern },
    // TASK-91: Song/Chain/Phrase（recorded）
    .{ .name = "phrase_capture", .run = actionPhraseCapture },
    .{ .name = "chain_set", .run = actionChainSet },
    .{ .name = "song_row", .run = actionSongRow },
    .{ .name = "song_len", .run = actionSongLen },
    .{ .name = "song_loop", .run = actionSongLoop },
    .{ .name = "song_play", .run = actionSongPlay },
    .{ .name = "song_goto", .run = actionSongGoto },
};

fn dispatchModularAction(ctx: *anyopaque, name: []const u8, args: []const u8, buf: []u8) anyerror![]const u8 {
    for (&MODULAR_ACTIONS) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e.run(ctx, args, buf);
    }
    return error.UnknownAction;
}

fn recordedAction(comptime name: []const u8) *const fn (*anyopaque, []const u8, []u8) anyerror![]const u8 {
    return &struct {
        fn run(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
            const app: *App = @ptrCast(@alignCast(ctx));
            const res = try app.cmd_exec.executeAction(name, args, .{
                .actor = .local_agent,
                .record_policy = .record,
            }, buf);
            return res.output;
        }
    }.run;
}

/// 全 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness 無効時は
/// `registerAction` 自体が no-op なので通常実行に影響しない）。記録 wrapper 経由。
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "set_param", .ctx = app, .run = recordedAction("set_param") });
    platform.registerAction(.{ .name = "set_mute", .ctx = app, .run = recordedAction("set_mute") });
    platform.registerAction(.{ .name = "set_lock", .ctx = app, .run = recordedAction("set_lock") });
    platform.registerAction(.{ .name = "set_evolve", .ctx = app, .run = recordedAction("set_evolve") });
    platform.registerAction(.{ .name = "toggle_step", .ctx = app, .run = recordedAction("toggle_step") });
    platform.registerAction(.{ .name = "set_pitch", .ctx = app, .run = recordedAction("set_pitch") });
    platform.registerAction(.{ .name = "save_pattern", .ctx = app, .run = recordedAction("save_pattern") });
    platform.registerAction(.{ .name = "load_pattern", .ctx = app, .run = recordedAction("load_pattern") });
    platform.registerAction(.{ .name = "seed", .ctx = app, .run = recordedAction("seed") });
    // TASK-93: mini-notation。レシピには記法の生テキストを記録（replay 時 counter 順で再評価→決定的）。
    platform.registerAction(.{ .name = "pattern", .ctx = app, .run = recordedAction("pattern") });
    // TASK-91: Song/Chain/Phrase（recorded。seed+recipe 決定性に整合）
    platform.registerAction(.{ .name = "phrase_capture", .ctx = app, .run = recordedAction("phrase_capture") });
    platform.registerAction(.{ .name = "chain_set", .ctx = app, .run = recordedAction("chain_set") });
    platform.registerAction(.{ .name = "song_row", .ctx = app, .run = recordedAction("song_row") });
    platform.registerAction(.{ .name = "song_len", .ctx = app, .run = recordedAction("song_len") });
    platform.registerAction(.{ .name = "song_loop", .ctx = app, .run = recordedAction("song_loop") });
    platform.registerAction(.{ .name = "song_play", .ctx = app, .run = recordedAction("song_play") });
    platform.registerAction(.{ .name = "song_goto", .ctx = app, .run = recordedAction("song_goto") });
    // recipe（TASK-62.5.8）: メタ操作のため executor 非経由・CommandLog 非記録。local_only。
    platform.registerAction(.{ .name = "recipe_save", .ctx = app, .run = actionRecipeSave, .network_policy = .local_only });
    platform.registerAction(.{ .name = "recipe_replay", .ctx = app, .run = actionRecipeReplay, .network_policy = .local_only });
    // render（TASK-86）: offline WAV 書き出し。recipe_save と同じ local_only・CommandLog 非記録。
    platform.registerAction(.{ .name = "render", .ctx = app, .run = actionRender, .network_policy = .local_only });
    // TASK-91: プロジェクト直列化（save_pattern 同型・local_only・非記録）
    platform.registerAction(.{ .name = "save_project", .ctx = app, .run = actionSaveProject, .network_policy = .local_only });
    platform.registerAction(.{ .name = "load_project", .ctx = app, .run = actionLoadProject, .network_policy = .local_only });
}

fn netsyncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const cmd = stateToCommand(patch.snapshotState());
    return pattern_io.encode(Params, allocator, app.params, patternToPayload(cmd));
}

fn netsyncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const app = actionApp(ctx);
    const patch = app.patch orelse return error.NotReady;
    const loaded = try pattern_io.decode(Params, bytes);
    app.params = loaded.params;
    publishControls(patch, app.params);
    app.pattern_rev += 1;
    const cmd = payloadToPatternCommand(app.pattern_rev, loaded.pattern);
    patch.controls.pattern_db.publish(cmd);
}

fn registerStateSync(app: *App) void {
    platform.registerStateSync(.{
        .ctx = app,
        .export_fn = netsyncExport,
        .import_fn = netsyncImport,
    });
}
