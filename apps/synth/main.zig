//! apps/synth — シンセ本体 (TASK-27.5 / 27.6 / 27.8)。
//!
//! 入力: PC キーボード(A..K=C4..C5) と GUI 画面鍵盤(クリック)。
//! 操作: GUI スライダで cutoff/resonance/gain/attack/release、ボタンで波形を変更（atomic/patch publish）。
//! 表示: 出力タップ→mono downmix→FFT のスペクトログラム。
//! 音は L1 audio の RT コールバックから Synth.render（GUI⇔Audio はロックフリー）。

const std = @import("std");
const platform = @import("platform");
const audio = @import("audio");
const synthlib = @import("synth");
const dsp = @import("dsp");
const gui = @import("gui");
const spectrogram = @import("spectrogram.zig");

const MAX_VOICES = 16;
const Synth = synthlib.Synth(MAX_VOICES);
const Tap = synthlib.SampleTap(8192);
const Patch = synthlib.Patch;

const NOTE_LOW = 60; // C4
const NOTE_HIGH = 72; // C5
const NOTE_COUNT = NOTE_HIGH - NOTE_LOW + 1;

// レイアウト（コントロールパネルは 3 カラム。パネル下にスペクトログラム、最下部に鍵盤）
const WIN_W = 860;
const WIN_H = 440;
const SPEC_X0 = 20;
const SPEC_Y0 = 250;
const SPEC_W = 820;
const SPEC_H = 120;
const PIANO_Y0 = 380;
const PIANO_H = 55;

const Spec = spectrogram.Spectrogram(SPEC_W, SPEC_H);

const App = struct {
    synth: Synth,
    tap: Tap,
};

fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.synth.render(buf, frames, channels);
    app.tap.write(buf);
}

fn keyToNote(key: platform.KeyCode) ?u8 {
    return switch (key) {
        .A => 60, .W => 61, .S => 62, .E => 63, .D => 64, .F => 65,
        .T => 66, .G => 67, .Y => 68, .H => 69, .U => 70, .J => 71, .K => 72,
        else => null,
    };
}

/// 画面鍵盤の当たり判定。ピアノ領域内の x,y からノート番号を返す。
fn pianoHitTest(x: i32, y: i32) ?u8 {
    if (y < PIANO_Y0 or y >= PIANO_Y0 + PIANO_H) return null;
    if (x < 0 or x >= WIN_W) return null;
    const idx = @as(usize, @intCast(x)) * NOTE_COUNT / WIN_W;
    return @intCast(NOTE_LOW + idx);
}

/// framebuffer のピクセル u32 packing（gui.Color と同じ: メモリ R,G,B,A = u32 0xAABBGGRR）。
fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

fn drawSpectrogramBgAndPiano(fb: platform.Framebuffer, pressed: *const [128]bool) void {
    const w: usize = fb.width;
    const h: usize = fb.height;
    @memset(fb.pixels, rgba(0x10, 0x10, 0x18, 0xFF)); // 暗い背景

    // 画面鍵盤（下部）。白鍵/黒鍵を区別し、押下中はハイライト。
    var note: usize = NOTE_LOW;
    while (note <= NOTE_HIGH) : (note += 1) {
        const idx = note - NOTE_LOW;
        const x0 = idx * w / NOTE_COUNT;
        const x1 = (idx + 1) * w / NOTE_COUNT;
        const semitone = note % 12;
        const is_black = (semitone == 1 or semitone == 3 or semitone == 6 or semitone == 8 or semitone == 10);
        const base: u32 = if (is_black) rgba(0x30, 0x30, 0x38, 0xFF) else rgba(0xC8, 0xC8, 0xD0, 0xFF);
        const lit: u32 = rgba(0xFF, 0xC0, 0x40, 0xFF); // 押下中(アンバー)
        const col = if (pressed[note]) lit else base;
        var y: usize = PIANO_Y0;
        while (y < @min(PIANO_Y0 + PIANO_H, h)) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) fb.pixels[y * w + x] = col;
        }
    }
}

const WAVE_NAMES = [_][]const u8{ "sine", "saw", "square", "triangle" };
fn waveOf(idx: usize) dsp.Waveform {
    return switch (idx) {
        0 => .sine,
        1 => .saw,
        2 => .square,
        else => .triangle,
    };
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

pub fn main() !void {
    std.debug.print("apps/synth: A..K=C4..C5 / 画面鍵盤クリック / スライダで音色変更 / ESC 終了\n", .{});

    const allocator = std.heap.c_allocator;

    var app = try allocator.create(App);
    defer allocator.destroy(app);

    // スライダ用パラメータ（GUI が in-place 更新）
    var params = Params{};

    app.* = .{
        .synth = Synth.init(48000, makePatch(params)),
        .tap = .{},
    };

    const spec = try allocator.create(Spec);
    defer allocator.destroy(spec);
    spec.init();

    try platform.init();
    defer platform.shutdown();

    var window = try platform.Window.create(WIN_W, WIN_H, "synth - keyboard + sliders + spectrogram");
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

    app.synth.sample_rate = @floatFromInt(device.config().sample_rate);
    try device.start();
    defer device.stop();

    var pressed = [_]bool{false} ** 128;
    var mouse_note: ?u8 = null; // マウスで押している鍵
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
                    if (k.key == .ESCAPE) {
                        running = false;
                    } else if (keyToNote(k.key)) |note| {
                        if (!k.is_repeat and !pressed[note]) {
                            pressed[note] = true;
                            _ = app.synth.sendNoteOn(note, 1.0);
                        }
                    }
                },
                .key_up => |k| {
                    if (keyToNote(k.key)) |note| {
                        if (pressed[note]) {
                            pressed[note] = false;
                            _ = app.synth.sendNoteOff(note);
                        }
                    }
                },
                .mouse_down => |m| {
                    if (pianoHitTest(m.x, m.y)) |note| {
                        mouse_note = note;
                        if (!pressed[note]) {
                            pressed[note] = true;
                            _ = app.synth.sendNoteOn(note, 1.0);
                        }
                    }
                },
                .mouse_up => {
                    if (mouse_note) |note| {
                        pressed[note] = false;
                        _ = app.synth.sendNoteOff(note);
                        mouse_note = null;
                    }
                },
                else => {},
            }
            if (toGuiEvent(ev)) |ge| ctx.pushEvent(ge);
        }

        // 出力タップを drain → mono downmix → スペクトログラム
        while (true) {
            const n = app.tap.read(&stereo);
            if (n < 2) break;
            const frames = n / 2;
            dsp.downmixStereoToMono(stereo[0 .. frames * 2], mono[0..frames]);
            spec.feed(mono[0..frames]);
        }

        // GUI コントロールパネル（上部）を構築。スライダは 2 カラムでパネルを低く保つ。
        ctx.beginBox(.{
            .direction = .column,
            .padding = .{ 10, 10, 10, 10 },
            .gap = 6,
            .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
        });
        ctx.label("Synth controls (drag knobs):");
        ctx.beginBox(.{ .direction = .row, .gap = 18 });
        // 左カラム: オシレータ/アンプ + キートラック
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x6001, "Cutoff   ", &params.cutoff, .{ .min = 100, .max = 18000, .step = 10 });
        _ = ctx.sliderF32Id(0x6002, "Resonance", &params.resonance, .{ .min = 0.5, .max = 8, .step = 0.1 });
        _ = ctx.sliderF32Id(0x6003, "Gain     ", &params.gain, .{ .min = 0, .max = 0.5, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6004, "Attack   ", &params.attack, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6005, "Release  ", &params.release, .{ .min = 0.01, .max = 2, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6006, "KeyTrack ", &params.keytrack, .{ .min = 0, .max = 1, .step = 0.05 });
        ctx.endBox();
        // 中カラム: フィルタ env + LFO
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x6007, "FiltEnv  ", &params.filter_env_amount, .{ .min = 0, .max = 5, .step = 0.1 });
        _ = ctx.sliderF32Id(0x6008, "FEnvAtk  ", &params.filter_attack, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6009, "FEnvDec  ", &params.filter_decay, .{ .min = 0.01, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x600A, "LFO Rate ", &params.lfo_rate, .{ .min = 0.1, .max = 20, .step = 0.1 });
        _ = ctx.sliderF32Id(0x600B, "Vibrato  ", &params.vibrato_depth, .{ .min = 0, .max = 2, .step = 0.05 });
        _ = ctx.sliderF32Id(0x600C, "Tremolo  ", &params.tremolo_depth, .{ .min = 0, .max = 1, .step = 0.05 });
        ctx.endBox();
        // 右カラム: ユニゾン / 2nd osc / ノイズ (27.13)
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x600D, "Unison   ", &params.unison, .{ .min = 1, .max = 7, .step = 1 });
        _ = ctx.sliderF32Id(0x600E, "Detune   ", &params.detune, .{ .min = 0, .max = 50, .step = 1 });
        _ = ctx.sliderF32Id(0x600F, "Osc2 Mix ", &params.osc2_mix, .{ .min = 0, .max = 1, .step = 0.05 });
        _ = ctx.sliderF32Id(0x6010, "Osc2 Det ", &params.osc2_detune, .{ .min = -24, .max = 24, .step = 1 });
        _ = ctx.sliderF32Id(0x6011, "Noise    ", &params.noise_amount, .{ .min = 0, .max = 1, .step = 0.05 });
        ctx.endBox();
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 8 });
        const wlabel = std.fmt.allocPrint(ctx.allocator(), "Wave: {s}", .{WAVE_NAMES[params.wave_idx]}) catch "Wave";
        if (ctx.button(wlabel)) params.wave_idx = (params.wave_idx + 1) % WAVE_NAMES.len;
        const flabel = std.fmt.allocPrint(ctx.allocator(), "Filter: {s}", .{FILTER_MODE_NAMES[params.filter_mode_idx]}) catch "Filter";
        if (ctx.button(flabel)) params.filter_mode_idx = (params.filter_mode_idx + 1) % FILTER_MODE_NAMES.len;
        const o2label = std.fmt.allocPrint(ctx.allocator(), "Osc2: {s}", .{WAVE_NAMES[params.osc2_wave_idx]}) catch "Osc2";
        if (ctx.button(o2label)) params.osc2_wave_idx = (params.osc2_wave_idx + 1) % WAVE_NAMES.len;
        ctx.endBox();
        ctx.endBox();
        ctx.endFrame();

        // パラメータを publish（atomic/patch publish 経由で audio スレッドへ。audio 側でスムージング）
        app.synth.publishPatch(makePatch(params));

        // 手動描画（背景 + 鍵盤 + スペクトログラム）→ その上に GUI
        drawSpectrogramBgAndPiano(fb, &pressed);
        spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, SPEC_Y0);
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font);

        window.present();

        var req = std.c.timespec{ .sec = 0, .nsec = 16_000_000 };
        _ = std.c.nanosleep(&req, null);
    }
}

/// GUI スライダ/ボタンが in-place 更新するパラメータ束。
const Params = struct {
    cutoff: f32 = 6000,
    resonance: f32 = 1.2,
    gain: f32 = 0.2,
    attack: f32 = 0.01,
    release: f32 = 0.2,
    wave_idx: usize = 1, // saw
    filter_mode_idx: usize = 0, // lowpass
    keytrack: f32 = 0.0,
    filter_env_amount: f32 = 0.0, // フィルタ env 量(オクターブ)
    filter_attack: f32 = 0.01,
    filter_decay: f32 = 0.2,
    lfo_rate: f32 = 5.0,
    vibrato_depth: f32 = 0.0, // 半音
    tremolo_depth: f32 = 0.0, // 0..1
    // オシレータ拡張(27.13)。unison はスライダ用に f32 で保持し makePatch で u8 へ。
    unison: f32 = 1,
    detune: f32 = 0.0, // cents
    osc2_mix: f32 = 0.0, // 0..1
    osc2_detune: f32 = 0.0, // 半音
    osc2_wave_idx: usize = 0, // sine
    noise_amount: f32 = 0.0, // 0..1
};

const FILTER_MODE_NAMES = [_][]const u8{ "LP", "HP", "BP", "notch" };
fn filterModeOf(idx: usize) dsp.FilterMode {
    return switch (idx) {
        0 => .lowpass,
        1 => .highpass,
        2 => .bandpass,
        else => .notch,
    };
}

fn makePatch(p: Params) Patch {
    return .{
        .waveform = waveOf(p.wave_idx),
        .attack = p.attack,
        .decay = 0.15,
        .sustain = 0.6,
        .release = p.release,
        .cutoff = p.cutoff,
        .resonance = p.resonance,
        .gain = p.gain,
        .filter_mode = filterModeOf(p.filter_mode_idx),
        .keytrack = p.keytrack,
        .filter_attack = p.filter_attack,
        .filter_decay = p.filter_decay,
        .filter_sustain = 0.0,
        .filter_release = 0.2,
        .filter_env_amount = p.filter_env_amount,
        .lfo_rate = p.lfo_rate,
        .vibrato_depth = p.vibrato_depth,
        .tremolo_depth = p.tremolo_depth,
        .unison = @intFromFloat(std.math.clamp(@round(p.unison), 1, 7)),
        .detune = p.detune,
        .osc2_waveform = waveOf(p.osc2_wave_idx),
        .osc2_detune = p.osc2_detune,
        .osc2_mix = p.osc2_mix,
        .noise_amount = p.noise_amount,
    };
}
