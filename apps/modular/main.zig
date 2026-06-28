//! apps/modular (run-modular): モジュラー生成パッチを「見て・弄れる」アプリ (Ph3 chunk B, TASK-40.3)。
//!
//! window を開き、L1 audio の RT callback で LofiPatch を render する。出力タップ→mono downmix→
//! スペクトログラム / オシロスコープ / レベルメータで可視化し、libs/gui のスライダ/mute ボタンで
//! テンポ・マスター cutoff・密度・スウィング・サイドチェイン量・各トラック gain/mute を
//! **リビルドなしで** 変更できる（GUI=store / RT=applyControls で load。RT 経路に lock/alloc/IO なし）。
//! ESC または閉じるで終了。
//!
//! harness 有効時: built-in audio probe（facade 自動 tap）で silent 判定でき、custom 'modular' probe で
//! 再生状態＋操作の反映状態を 1 行 digest として公開する（harness 無効時 registerProbe は no-op）。

const std = @import("std");
const platform = @import("platform");
const audio = @import("audio");
const synth = @import("synth"); // SampleTap（Audio→GUI の出力タップ）
const dsp = @import("dsp"); // mono downmix
const gui = @import("gui"); // スライダ / ボタン
const spectrogram = @import("spectrogram"); // apps/synth 流用（build.zig で module 化）
const scope = @import("scope"); // apps/synth 流用（オシロ / レベルメータ）
const LofiPatch = @import("patch.zig").LofiPatch;

// ウィンドウ。上部=GUI コントロール、下部=可視化帯（spectrogram / scope / level meter）。
const WIN_W = 960;
const WIN_H = 540;
const BG: u32 = 0xFF101418; // 暗いグレー（canonical BGRA 0xAARRGGBB）

const VIS_Y0 = 320; // 可視化帯の上端
const VIS_H = 190;
const SPEC_X0 = 16;
const SPEC_W = 560;
const SCOPE_X0 = 590;
const SCOPE_W = 290;
const METER_X0 = 896;
const METER_W = 48;

const Spec = spectrogram.Spectrogram(SPEC_W, VIS_H);
const Scope = scope.Oscilloscope(SCOPE_W, VIS_H);

const Tap = synth.SampleTap(8192); // interleaved stereo を溜める（drop 可）

// master cutoff の対数マップ範囲（patch.zig の master_cutoff clamp 範囲に一致）。
const CUTOFF_MIN: f32 = 80.0;
const CUTOFF_MAX: f32 = 18000.0;

/// audio userdata。patch は audio.open 後・start 前に effective sample_rate で生成して差し込む。
const App = struct {
    patch: ?*LofiPatch = null,
    tap: Tap = .{},
};

/// RT スレッドで呼ばれる（alloc/lock/IO/panic 禁止）。patch 未設定なら無音。
fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate; // graph は生成時の effective sample_rate で動く
    const app: *App = @ptrCast(@alignCast(userdata orelse {
        @memset(buf, 0); // userdata 不正でも stale を鳴らさない
        return;
    }));
    if (app.patch) |p| {
        p.render(buf, frames, channels);
        // 可視化タップは stereo 前提（read 側が frames=n/2 で downmix）。stereo の時だけ供給する。
        if (channels == 2) app.tap.write(buf); // interleaved stereo をコピー（drop 可）
    } else {
        @memset(buf, 0);
    }
}

// ----------------------------------------------------------------------------
// GUI スライダ/ボタンが in-place 更新するパラメータ束。既定は patch の Controls 既定に一致。
// ----------------------------------------------------------------------------
const Params = struct {
    tempo: f32 = 122.0, // BPM
    cutoff_norm: f32 = 1.0, // 0..1（対数マップして Hz へ。1.0=オープン）
    density: f32 = 1.0, // 0..2
    swing: f32 = 0.0, // 0..1
    sidechain: f32 = 0.35, // 0..1
    kick_gain: f32 = 1.0, // 倍率
    hat_gain: f32 = 1.0,
    clap_gain: f32 = 1.0,
    bass_gain: f32 = 1.0,
    pad_gain: f32 = 1.0,
    kick_mute: bool = false,
    hat_mute: bool = false,
    clap_mute: bool = false,
    bass_mute: bool = false,
    pad_mute: bool = false,
    // Ph4 音色マクロ（集約ノブ）。細かい個別パラメータは patch.zig のコード既定固定。
    kick_punch: f32 = 1.0, // kick click 量（倍率）
    hat_bright: f32 = 1.0, // hat 明るさ
    hat_decay: f32 = 0.045, // hat 減衰(s)
    pad_cutoff: f32 = 1400.0, // pad LP cutoff(Hz)
    pad_warmth: f32 = 0.6, // pad 温かみ(0..1)
    master_warmth: f32 = 0.5, // master saturation(0..1)
};

/// 0..1 の正規化値を対数で cutoff(Hz) へ。norm=1 → CUTOFF_MAX（ほぼ素通し）。
fn cutoffHz(norm: f32) f32 {
    const n = std.math.clamp(norm, 0.0, 1.0);
    return CUTOFF_MIN * std.math.pow(f32, CUTOFF_MAX / CUTOFF_MIN, n);
}

/// Params を patch.Controls(atomic) へ publish（GUI=store。RT 側 applyControls が load）。
fn publishControls(patch: *LofiPatch, p: Params) void {
    const c = &patch.controls;
    c.tempo_bpm.store(p.tempo);
    c.master_cutoff.store(cutoffHz(p.cutoff_norm));
    c.density.store(p.density);
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
    // Ph4 音色マクロ
    c.kick_punch.store(p.kick_punch);
    c.hat_bright.store(p.hat_bright);
    c.hat_decay.store(p.hat_decay);
    c.pad_cutoff.store(p.pad_cutoff);
    c.pad_warmth.store(p.pad_warmth);
    c.master_warmth.store(p.master_warmth);
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
// 可視化の手動描画（メインスレッド）。背景 + spectrogram/scope/meter + ラベル。
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

/// spectrogram に周波数 tick/ラベル（左内側）と、3 パネルのタイトルを重ね描き。
fn drawVizLabels(fb: platform.Framebuffer, spec: *const Spec) void {
    const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
    const clip: gui.Rect = .{ .x = 0, .y = 0, .w = @intCast(fb.width), .h = @intCast(fb.height) };
    const label_col = gui.Color.rgba(0xE0, 0xE0, 0xE0, 0xFF);
    const tick_col: u32 = 0xFFFFFFFF;

    // パネルタイトル（帯の上）
    const title_y: i32 = VIS_Y0 - 14;
    gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0, .y = title_y }, "SPECTROGRAM", label_col, clip);
    gui.default_bitmap_font.drawTo(target, .{ .x = SCOPE_X0, .y = title_y }, "SCOPE", label_col, clip);
    gui.default_bitmap_font.drawTo(target, .{ .x = METER_X0 - 4, .y = title_y }, "LVL", label_col, clip);

    // 周波数 tick/ラベル（対数軸位置）。tick は実位置、テキスト y は帯内へ clamp。
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
// ctx は *App。snapshotState は audio RT が更新する状態を torn read する best-effort。
// ============================================================================
fn modularDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const p = app.patch orelse return std.fmt.bufPrint(buf, "{{\"playing\":false}}", .{}) catch buf[0..0];
    const st = p.snapshotState(); // best-effort（RT 更新中の torn 可）
    // bufPrint は 1 呼び出し 32 引数上限のため 2 回に分けて同じ buf へ連結する（1 行 JSON）。
    const a = std.fmt.bufPrint(buf, "{{\"playing\":true,\"bpm\":{d:.0},\"clock_phase\":{d:.3},\"density\":{d:.3}," ++
        "\"swing\":{d:.3},\"sidechain\":{d:.3},\"master_cutoff\":{d:.0}," ++
        "\"bass_pitch_cv\":{d:.4},\"turing_register\":{d},\"turing_cv\":{d:.4}," ++
        "\"steps\":{{\"kick\":{d},\"hat\":{d},\"clap\":{d},\"bass\":{d}}}," ++
        "\"active\":{{\"kick\":{},\"hat\":{},\"clap\":{},\"pad\":{}}}," ++
        "\"gains\":{{\"kick\":{d:.3},\"hat\":{d:.3},\"clap\":{d:.3},\"bass\":{d:.3},\"pad\":{d:.3}}}," ++
        "\"muted\":{{\"kick\":{},\"hat\":{},\"clap\":{},\"bass\":{},\"pad\":{}}},", .{
        st.bpm,           st.clock_phase,      st.density,
        st.swing,         st.sidechain_amount, st.master_cutoff,
        st.bass_pitch_cv, st.turing_register,  st.turing_cv,
        st.kick_step,     st.hat_step,         st.clap_step,   st.bass_step,
        st.kick_active,   st.hat_active,       st.clap_active, st.pad_active,
        st.kick_gain,     st.hat_gain,         st.clap_gain,   st.bass_gain,  st.pad_gain,
        st.kick_muted,    st.hat_muted,        st.clap_muted,  st.bass_muted, st.pad_muted,
    }) catch return buf[0..0];
    const b = std.fmt.bufPrint(buf[a.len..], "\"ph4\":{{\"kick_click\":{d:.3},\"hat_bright\":{d:.3}," ++
        "\"pad_cutoff\":{d:.0},\"pad_warmth\":{d:.3},\"master_drive\":{d:.3}," ++
        "\"pre_clip_peak\":{d:.3},\"clip_rate\":{d:.4}}}," ++
        "\"tracks\":[\"kick\",\"hat\",\"clap\",\"bass\",\"pad\"]}}", .{
        st.kick_click_gain, st.hat_brightness, st.pad_cutoff, st.pad_warmth,
        st.master_drive,    st.pre_clip_peak,  st.clip_rate,
    }) catch return buf[0..a.len];
    return buf[0 .. a.len + b.len];
}

fn modularSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [1024]u8 = undefined;
    return allocator.dupe(u8, modularDigest(ctx, &buf));
}

pub fn main() !void {
    std.debug.print("apps/modular: lofi テクノ生成パッチ（スライダで操作・ESC で終了）\n", .{});

    // audio backend は libc を link しているので c_allocator を使う（RT 外の確保用）。
    const allocator = std.heap.c_allocator;

    // App は tap が大きいのでヒープ確保（RT へ渡す userdata。寿命安定）。
    const app = try allocator.create(App);
    defer allocator.destroy(app);
    app.* = .{};

    // 可視化（spectrogram は大きいのでヒープ確保。scope ring も大きいので同様）。
    const spec = try allocator.create(Spec);
    defer allocator.destroy(spec);
    spec.init(48000); // 仮 sr。audio.open 後に setSampleRate で対数軸を再算出
    const osc = try allocator.create(Scope);
    defer allocator.destroy(osc);
    osc.* = .{};
    var meter = scope.LevelMeter{};

    var params = Params{};

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "modular - lofi techno (play & see)");
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

    // effective sample_rate でパッチを生成し、start 前に差し込む（callback は start まで発火しない）。
    const sr: f32 = @floatFromInt(device.config().sample_rate);
    const patch = LofiPatch.create(allocator, sr) catch |err| {
        std.debug.print("patch init failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer patch.destroy();
    app.patch = patch;
    spec.setSampleRate(sr); // 対数周波数軸を実 sr で再算出

    device.start() catch |err| {
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer device.stop();

    // harness custom probe（無効時 no-op）。app はヒープ確保で寿命安定。
    platform.registerProbe(.{ .name = "modular", .ctx = app, .ext = "json", .snapshot = modularSnapshot, .digest = modularDigest });

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

        // 出力タップを drain → mono downmix → spectrogram / scope / level meter
        while (true) {
            const n = app.tap.read(&stereo);
            if (n < 2) break;
            const frames = n / 2;
            dsp.downmixStereoToMono(stereo[0 .. frames * 2], mono[0..frames]);
            spec.feed(mono[0..frames]);
            osc.feed(mono[0..frames]);
            meter.feed(mono[0..frames]);
        }

        // GUI コントロールパネル（上部）。3 カラム（Global / Levels / Tone）＋ mute ボタン行。
        // Tone カラム＝Ph4 音色マクロ（集約ノブ）。細かい個別パラメータは出さない（過密回避）。
        ctx.beginBox(.{
            .direction = .column,
            .padding = .{ 10, 10, 10, 10 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });
        ctx.label("modular - lofi techno (drag sliders / click mute):");
        ctx.beginBox(.{ .direction = .row, .gap = 18 });
        // 左カラム: グローバル
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x7001, "Tempo    ", &params.tempo, .{ .min = 60, .max = 180, .step = 1 });
        _ = ctx.sliderF32Id(0x7002, "Cutoff   ", &params.cutoff_norm, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x7003, "Density  ", &params.density, .{ .min = 0, .max = 2, .step = 0.05 });
        _ = ctx.sliderF32Id(0x7004, "Swing    ", &params.swing, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x7005, "Sidechain", &params.sidechain, .{ .min = 0, .max = 1, .step = 0.01 });
        ctx.endBox();
        // 中カラム: 各トラック level
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x7006, "Kick Gain", &params.kick_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x7007, "Hat Gain ", &params.hat_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x7008, "Clap Gain", &params.clap_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x7009, "Bass Gain", &params.bass_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x700A, "Pad Level", &params.pad_gain, .{ .min = 0, .max = 1.5, .step = 0.05 });
        ctx.endBox();
        // 右カラム: Ph4 音色マクロ（Tone）
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x700B, "KickPunch", &params.kick_punch, .{ .min = 0, .max = 2, .step = 0.05 });
        _ = ctx.sliderF32Id(0x700C, "Hat Bright", &params.hat_bright, .{ .min = 0.3, .max = 2.5, .step = 0.05 });
        _ = ctx.sliderF32Id(0x700D, "Hat Decay", &params.hat_decay, .{ .min = 0.01, .max = 0.2, .step = 0.005 });
        _ = ctx.sliderF32Id(0x700E, "Pad Cutoff", &params.pad_cutoff, .{ .min = 200, .max = 6000, .step = 50 });
        _ = ctx.sliderF32Id(0x700F, "Pad Warm ", &params.pad_warmth, .{ .min = 0, .max = 1, .step = 0.02 });
        _ = ctx.sliderF32Id(0x7010, "Mst Warm ", &params.master_warmth, .{ .min = 0, .max = 1, .step = 0.02 });
        ctx.endBox();
        ctx.endBox();
        // mute ボタン行
        ctx.beginBox(.{ .direction = .row, .gap = 8 });
        if (ctx.button(if (params.kick_mute) "Kick: MUTE" else "Kick: on")) params.kick_mute = !params.kick_mute;
        if (ctx.button(if (params.hat_mute) "Hat: MUTE" else "Hat: on")) params.hat_mute = !params.hat_mute;
        if (ctx.button(if (params.clap_mute) "Clap: MUTE" else "Clap: on")) params.clap_mute = !params.clap_mute;
        if (ctx.button(if (params.bass_mute) "Bass: MUTE" else "Bass: on")) params.bass_mute = !params.bass_mute;
        if (ctx.button(if (params.pad_mute) "Pad: MUTE" else "Pad: on")) params.pad_mute = !params.pad_mute;
        ctx.endBox();
        ctx.endBox();
        ctx.endFrame();

        // GUI 操作を patch.Controls(atomic) へ publish（RT 側 applyControls が load）。
        publishControls(patch, params);

        // 手動描画（背景 + 可視化）→ その上に GUI
        @memset(fb.pixels, BG);
        spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, VIS_Y0);
        osc.draw(fb.pixels, fb.width, fb.height, SCOPE_X0, VIS_Y0);
        meter.draw(fb.pixels, fb.width, fb.height, METER_X0, VIS_Y0, METER_W, VIS_H);
        drawVizLabels(fb, spec);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font);

        window.present();
        platform.sleep(16_000_000); // ~60fps
    }

    std.debug.print("apps/modular: done.\n", .{});
}
