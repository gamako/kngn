//! apps/synth — シンセ本体 (TASK-27.5 / 27.6 / 27.8 / 27.13-27.16)。
//!
//! 入力: PC キーボード(A..K=C4..C5) と GUI 画面鍵盤(クリック)。
//! 操作: GUI スライダ/ボタンで音色(osc/filter/env/LFO/unison/osc2/noise)とマスター FX(delay/chorus/dist/reverb)を変更。
//! 表示: 出力タップ→mono downmix→ スペクトログラム / オシロスコープ / ピーク・RMS レベルメータ。
//! 音は L1 audio の RT コールバックから Synth.render→MasterEffects.process（GUI⇔Audio はロックフリー）。

const std = @import("std");
const kit = @import("kit"); // 公開 umbrella（ADR-007 R4/R5: apps は kit-only 消費者）
const platform = kit.platform;
const audio = kit.audio;
const synthlib = kit.synth;
const dsp = kit.dsp;
const gui = kit.gui;
const spectrogram = @import("spectrogram");
const scope = @import("scope");
const actions = @import("actions.zig");

const MAX_VOICES = 16;
const Synth = synthlib.Synth(MAX_VOICES);
const Tap = synthlib.SampleTap(8192);
const Patch = synthlib.Patch;
// マスターエフェクト: delay ~1.36s(65536@48k) / chorus ~85ms(4096@48k, 96kHz でも余裕)。いずれも 2 の冪。
const Fx = synthlib.MasterEffects(65536, 4096);

const NOTE_LOW = 60; // C4
const NOTE_HIGH = 72; // C5
const NOTE_COUNT = NOTE_HIGH - NOTE_LOW + 1;

// レイアウト（コントロールパネルは 4 カラム。FX カラムが 11 行と高いので縦に余裕を持たせる）
// 可視化帯(y 300〜420, h 120)を横に分割: スペクトログラム / オシロスコープ / レベルメータ。
const WIN_W = 1080;
const WIN_H = 520;
const SPEC_X0 = 20;
const SPEC_Y0 = 300;
const SPEC_W = 680;
const SPEC_H = 120;
const SCOPE_X0 = 710;
const SCOPE_W = 300;
const METER_X0 = 1018;
const METER_W = 52;
const VIS_Y0 = 300; // 可視化帯の上端(SPEC/SCOPE/METER 共通)
const VIS_H = 120;
const PIANO_Y0 = 440;
const PIANO_H = 55;

const Spec = spectrogram.Spectrogram(SPEC_W, SPEC_H);
const Scope = scope.Oscilloscope(SCOPE_W, VIS_H);

const App = struct {
    synth: Synth,
    fx: Fx,
    /// GUI 側で最後に publish した patch のコピー（patch probe 用。TASK-56。
    /// Mailbox の consumer 状態は RT 専有のため probe からは触らない）
    last_patch: Patch = .{},
    tap: Tap,
    /// GUI スライダ/ボタンが in-place 更新するパラメータ束（TASK-65: harness action からも
    /// 同じ field を書き換えられるよう main() ローカルから App へ移設）。
    params: Params = .{},
    fxp: FxParams = .{},
};

fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.synth.render(buf, frames, channels);
    app.fx.process(buf, frames, channels); // マスターエフェクト(出力タップの前)
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

/// framebuffer のピクセル u32 packing（gui.Color と同じ: メモリ B,G,R,A = u32 0xAARRGGBB）。
fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, b) | (@as(u32, g) << 8) | (@as(u32, r) << 16) | (@as(u32, a) << 24);
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

/// スペクトログラムに対数周波数ラベル(左内側)と dB カラースケール凡例(帯の下のすき間)を重ね描き。
fn drawSpecLabels(fb: platform.Framebuffer, spec: *const Spec) void {
    const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
    const clip: gui.Rect = .{ .x = 0, .y = 0, .w = @intCast(fb.width), .h = @intCast(fb.height) };
    const label_col = gui.Color.rgba(0xE0, 0xE0, 0xE0, 0xFF);
    const tick_col = rgba(0xFF, 0xFF, 0xFF, 0xFF);

    // 周波数ラベル(対数軸位置)。tick は実位置、テキスト y は領域内に clamp。
    const ty_min: i32 = SPEC_Y0;
    const ty_max: i32 = SPEC_Y0 + SPEC_H - 16; // font 高 16 ぶん上端を確保
    for (FREQ_LABELS) |fl| {
        const off = spec.rowOffsetForFreq(fl.hz) orelse continue;
        const tick_y = SPEC_Y0 + off;
        var tx: usize = SPEC_X0;
        while (tx < SPEC_X0 + 6) : (tx += 1) putFb(fb, tx, tick_y, tick_col);
        const ty = std.math.clamp(@as(i32, @intCast(tick_y)) - 8, ty_min, ty_max);
        gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0 + 8, .y = ty }, fl.text, label_col, clip);
    }

    // dB カラースケール凡例(帯の下 y=420..440): "-60dB" [横グラデ] "0dB"
    const leg_y = SPEC_Y0 + SPEC_H + 2; // 422
    const bar_x0 = SPEC_X0 + 56; // "-60dB"(5文字=40px)の右
    const bar_w: usize = 160;
    const bar_y = leg_y + 2;
    const bar_h: usize = 10;
    gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0, .y = leg_y }, "-60dB", label_col, clip);
    var lx: usize = 0;
    while (lx < bar_w) : (lx += 1) {
        const v: u8 = @intCast(lx * 255 / (bar_w - 1));
        const c = spectrogram.intensityColor(v);
        var ly: usize = 0;
        while (ly < bar_h) : (ly += 1) putFb(fb, bar_x0 + lx, bar_y + ly, c);
    }
    gui.default_bitmap_font.drawTo(target, .{ .x = bar_x0 + bar_w + 6, .y = leg_y }, "0dB", label_col, clip);
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

// ============================================================================
// ヘッドレス検証 harness の custom probe（TASK-32.3）
//
// `platform.registerProbe` で opt-in 登録。framework は中身非解釈で raw+digest をルートするだけ。
// ctx は *App。voices/patch は audio RT スレッドが更新するため main スレッドからの読み出しは torn し得る
// best-effort スナップショット（既存 audio probe と同じ debug 方針）。RT 経路には同期/alloc/lock を足さない。
// ============================================================================

/// VoicePool の占有状態を JSON 1行に整形（active voice の note/stage を列挙）。
fn formatVoices(app: *App, buf: []u8) []const u8 {
    var len: usize = 0;
    len += (std.fmt.bufPrint(buf[len..], "{{\"active\":{d},\"capacity\":{d},\"voices\":[", .{
        app.synth.pool.activeCount(), MAX_VOICES,
    }) catch return buf[0..len]).len;
    var first = true;
    for (&app.synth.pool.voices) |*v| {
        if (!v.active) continue;
        const sep = if (first) "" else ",";
        first = false;
        len += (std.fmt.bufPrint(buf[len..], "{s}{{\"note\":{d},\"stage\":\"{s}\"}}", .{
            sep, v.note, @tagName(v.stage()),
        }) catch break).len;
    }
    len += (std.fmt.bufPrint(buf[len..], "]}}", .{}) catch return buf[0..len]).len;
    return buf[0..len];
}

/// 公開中 patch を JSON 1行に整形。
/// Mailbox の consumer 状態（RT 専有）に触れないよう、GUI 側コピー（last_patch）を読む（TASK-56）。
/// probe は GUI と同一スレッド（main）なので plain read で安全。
fn formatPatch(app: *App, buf: []u8) []const u8 {
    const p = app.last_patch;
    return std.fmt.bufPrint(buf, "{{\"wave\":\"{s}\",\"filter\":\"{s}\",\"cutoff\":{d:.1},\"res\":{d:.2},\"gain\":{d:.3},\"attack\":{d:.3},\"release\":{d:.3},\"unison\":{d}}}", .{
        @tagName(p.waveform), @tagName(p.filter_mode), p.cutoff, p.resonance, p.gain, p.attack, p.release, p.unison,
    }) catch buf[0..0];
}

fn voicesDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    return formatVoices(@ptrCast(@alignCast(ctx)), buf);
}
fn voicesSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [1024]u8 = undefined;
    return allocator.dupe(u8, formatVoices(@ptrCast(@alignCast(ctx)), &buf));
}
fn patchDigest(ctx: *anyopaque, buf: []u8) []const u8 {
    return formatPatch(@ptrCast(@alignCast(ctx)), buf);
}
fn patchSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    var buf: [512]u8 = undefined;
    return allocator.dupe(u8, formatPatch(@ptrCast(@alignCast(ctx)), &buf));
}

pub fn main() !void {
    std.debug.print("apps/synth: A..K=C4..C5 / 画面鍵盤クリック / スライダで音色変更 / ESC 終了\n", .{});

    const allocator = std.heap.c_allocator;

    var app = try allocator.create(App);
    defer allocator.destroy(app);

    // スライダ/harness action が in-place 更新するパラメータ束は App.params/App.fxp（TASK-65）。
    const initial_patch = makePatch(Params{});
    app.* = .{
        .synth = Synth.init(48000, initial_patch),
        .fx = Fx.init(48000, makeFxParams(FxParams{})),
        .last_patch = initial_patch, // probe が初回 frame 前でも実際の初期 patch を返すように
        .tap = .{},
    };

    const spec = try allocator.create(Spec);
    defer allocator.destroy(spec);
    spec.init(48000); // 仮 sr。audio.open 後に setSampleRate で対数軸を再算出

    // オシロスコープ(リング大なので heap 確保) + レベルメータ
    const osc = try allocator.create(Scope);
    defer allocator.destroy(osc);
    osc.* = .{};
    var meter = scope.LevelMeter{};

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
    app.fx.setSampleRate(@floatFromInt(device.config().sample_rate)); // reverb タップ再算出(start 前)
    spec.setSampleRate(@floatFromInt(device.config().sample_rate)); // 対数周波数軸を実 sr で再算出
    try device.start();
    defer device.stop();

    // ヘッドレス検証 harness の custom probe を登録（harness 無効時は no-op）。app は heap 確保で寿命安定。
    platform.registerProbe(.{ .name = "voices", .ctx = app, .ext = "json", .snapshot = voicesSnapshot, .digest = voicesDigest });
    platform.registerProbe(.{ .name = "patch", .ctx = app, .ext = "json", .snapshot = patchSnapshot, .digest = patchDigest });
    // ヘッドレス検証 harness の custom action を登録（harness 無効時は no-op。TASK-65）。
    registerActions(app);

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

        // 出力タップを drain → mono downmix → スペクトログラム / オシロスコープ / レベルメータ
        while (true) {
            const n = app.tap.read(&stereo);
            if (n < 2) break;
            const frames = n / 2;
            dsp.downmixStereoToMono(stereo[0 .. frames * 2], mono[0..frames]);
            spec.feed(mono[0..frames]);
            osc.feed(mono[0..frames]);
            meter.feed(mono[0..frames]);
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
        _ = ctx.sliderF32Id(0x6001, "Cutoff   ", &app.params.cutoff, .{ .min = 100, .max = 18000, .step = 10 });
        _ = ctx.sliderF32Id(0x6002, "Resonance", &app.params.resonance, .{ .min = 0.5, .max = 8, .step = 0.1 });
        _ = ctx.sliderF32Id(0x6003, "Gain     ", &app.params.gain, .{ .min = 0, .max = 0.5, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6004, "Attack   ", &app.params.attack, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6005, "Release  ", &app.params.release, .{ .min = 0.01, .max = 2, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6006, "KeyTrack ", &app.params.keytrack, .{ .min = 0, .max = 1, .step = 0.05 });
        ctx.endBox();
        // 中カラム: フィルタ env + LFO
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x6007, "FiltEnv  ", &app.params.filter_env_amount, .{ .min = 0, .max = 5, .step = 0.1 });
        _ = ctx.sliderF32Id(0x6008, "FEnvAtk  ", &app.params.filter_attack, .{ .min = 0, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6009, "FEnvDec  ", &app.params.filter_decay, .{ .min = 0.01, .max = 1, .step = 0.01 });
        _ = ctx.sliderF32Id(0x600A, "LFO Rate ", &app.params.lfo_rate, .{ .min = 0.1, .max = 20, .step = 0.1 });
        _ = ctx.sliderF32Id(0x600B, "Vibrato  ", &app.params.vibrato_depth, .{ .min = 0, .max = 2, .step = 0.05 });
        _ = ctx.sliderF32Id(0x600C, "Tremolo  ", &app.params.tremolo_depth, .{ .min = 0, .max = 1, .step = 0.05 });
        ctx.endBox();
        // 右カラム: ユニゾン / 2nd osc / ノイズ (27.13)
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x600D, "Unison   ", &app.params.unison, .{ .min = 1, .max = 7, .step = 1 });
        _ = ctx.sliderF32Id(0x600E, "Detune   ", &app.params.detune, .{ .min = 0, .max = 50, .step = 1 });
        _ = ctx.sliderF32Id(0x600F, "Osc2 Mix ", &app.params.osc2_mix, .{ .min = 0, .max = 1, .step = 0.05 });
        _ = ctx.sliderF32Id(0x6010, "Osc2 Det ", &app.params.osc2_detune, .{ .min = -24, .max = 24, .step = 1 });
        _ = ctx.sliderF32Id(0x6011, "Noise    ", &app.params.noise_amount, .{ .min = 0, .max = 1, .step = 0.05 });
        ctx.endBox();
        // FX カラム: マスターエフェクト (27.14)
        ctx.beginBox(.{ .direction = .column, .gap = 4 });
        _ = ctx.sliderF32Id(0x6012, "Dly Time ", &app.fxp.delay_time, .{ .min = 0.01, .max = 1.0, .step = 0.01 });
        _ = ctx.sliderF32Id(0x6013, "Dly FB   ", &app.fxp.delay_fb, .{ .min = 0, .max = 0.95, .step = 0.05 });
        _ = ctx.sliderF32Id(0x6014, "Dly Mix  ", &app.fxp.delay_mix, .{ .min = 0, .max = 1, .step = 0.05 });
        _ = ctx.sliderF32Id(0x6015, "Cho Rate ", &app.fxp.chorus_rate, .{ .min = 0.1, .max = 8, .step = 0.1 });
        _ = ctx.sliderF32Id(0x6016, "Cho Depth", &app.fxp.chorus_depth, .{ .min = 0.5, .max = 10, .step = 0.5 });
        _ = ctx.sliderF32Id(0x6017, "Cho Mix  ", &app.fxp.chorus_mix, .{ .min = 0, .max = 1, .step = 0.05 });
        _ = ctx.sliderF32Id(0x6018, "Dist Drv ", &app.fxp.dist_drive, .{ .min = 1, .max = 20, .step = 0.5 });
        _ = ctx.sliderF32Id(0x6019, "Dist Mix ", &app.fxp.dist_mix, .{ .min = 0, .max = 1, .step = 0.05 });
        _ = ctx.sliderF32Id(0x601A, "Rev Mix  ", &app.fxp.reverb_mix, .{ .min = 0, .max = 1, .step = 0.05 });
        _ = ctx.sliderF32Id(0x601B, "Rev Decay", &app.fxp.reverb_decay, .{ .min = 0, .max = 1, .step = 0.05 });
        _ = ctx.sliderF32Id(0x601C, "Rev Damp ", &app.fxp.reverb_damping, .{ .min = 0, .max = 1, .step = 0.05 });
        ctx.endBox();
        ctx.endBox();
        ctx.beginBox(.{ .direction = .row, .gap = 8 });
        const wlabel = std.fmt.allocPrint(ctx.allocator(), "Wave: {s}", .{WAVE_NAMES[app.params.wave_idx]}) catch "Wave";
        if (ctx.button(wlabel)) app.params.wave_idx = (app.params.wave_idx + 1) % WAVE_NAMES.len;
        const flabel = std.fmt.allocPrint(ctx.allocator(), "Filter: {s}", .{FILTER_MODE_NAMES[app.params.filter_mode_idx]}) catch "Filter";
        if (ctx.button(flabel)) app.params.filter_mode_idx = (app.params.filter_mode_idx + 1) % FILTER_MODE_NAMES.len;
        const o2label = std.fmt.allocPrint(ctx.allocator(), "Osc2: {s}", .{WAVE_NAMES[app.params.osc2_wave_idx]}) catch "Osc2";
        if (ctx.button(o2label)) app.params.osc2_wave_idx = (app.params.osc2_wave_idx + 1) % WAVE_NAMES.len;
        const fxlabel = if (app.fxp.bypass) "FX: off" else "FX: on";
        if (ctx.button(fxlabel)) app.fxp.bypass = !app.fxp.bypass;
        ctx.endBox();
        ctx.endBox();
        ctx.endFrame();

        // パラメータを publish（atomic/patch publish 経由で audio スレッドへ。audio 側でスムージング）
        app.last_patch = makePatch(app.params);
        app.synth.publishPatch(app.last_patch);
        app.fx.publishParams(makeFxParams(app.fxp));

        // 手動描画（背景 + 鍵盤 + スペクトログラム + オシロ + メータ）→ その上に GUI
        drawSpectrogramBgAndPiano(fb, &pressed);
        spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, SPEC_Y0);
        osc.draw(fb.pixels, fb.width, fb.height, SCOPE_X0, VIS_Y0);
        meter.draw(fb.pixels, fb.width, fb.height, METER_X0, VIS_Y0, METER_W, VIS_H);
        drawSpecLabels(fb, spec); // 周波数ラベル + カラースケール凡例
        const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
        gui.render(target, &ctx.draw_list, ctx.font);

        window.present();

        platform.frameDelay(16_000_000); // ~16ms（約 60fps）
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

/// マスターエフェクト用 GUI パラメータ束(in-place 更新)。
const FxParams = struct {
    bypass: bool = false,
    delay_time: f32 = 0.25, // 秒
    delay_fb: f32 = 0.3,
    delay_mix: f32 = 0.0,
    chorus_rate: f32 = 0.8, // Hz
    chorus_depth: f32 = 3.0, // ms
    chorus_mix: f32 = 0.0,
    dist_drive: f32 = 1.0,
    dist_mix: f32 = 0.0,
    reverb_mix: f32 = 0.0,
    reverb_decay: f32 = 0.5,
    reverb_damping: f32 = 0.3,
};

fn makeFxParams(p: FxParams) Fx.Params {
    return .{
        .bypass = p.bypass,
        .delay_time_s = p.delay_time,
        .delay_feedback = p.delay_fb,
        .delay_mix = p.delay_mix,
        .chorus_rate = p.chorus_rate,
        .chorus_depth_ms = p.chorus_depth,
        .chorus_mix = p.chorus_mix,
        .dist_drive = p.dist_drive,
        .dist_mix = p.dist_mix,
        .reverb_mix = p.reverb_mix,
        .reverb_decay = p.reverb_decay,
        .reverb_damping = p.reverb_damping,
    };
}

// ============================================================================
// ヘッドレス検証 harness の custom action（TASK-65。TASK-62.1 の registerAction を synth が採用。
// pixie(TASK-64) と同じ「probe(read) に対称な write 口。UI と同じ App.params/App.fxp field を
// 書き換えるだけ」構図）。
//
// ホットパス宣言: 全 action の `run()` は「イベント時のみ」（harness `action` コマンド1回につき1回、
// main thread の pollGate 内で実行）。フレーム毎・毎サンプルのいずれでもないため性能規約の適用対象外。
// action が触れる状態伝播は既存の RT-safe cross-thread hand-off（`Synth.publishPatch` /
// `MasterEffects.publishParams`。いずれも atomic/Mailbox 経由で、毎フレーム GUI が呼ぶ既存コード
// パスと同一）をそのまま使うだけで、RT 経路（`Synth.render`/`MasterEffects.process`）へ新たな
// 同期/alloc/lock/panic は一切追加しない。
//
// パーサは `actions.zig`（std のみ・App/kit/dsp 非依存）に切り出し単体テストする。enum 名解決
// （wave/filter 名 → index）は App の具象型を知るこのファイル側で行う（pixie の `ToolKind` 解決と
// 同じ分離方針）。
// ============================================================================

fn actionApp(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

fn republishPatch(app: *App) void {
    app.last_patch = makePatch(app.params);
    app.synth.publishPatch(app.last_patch);
}

fn republishFx(app: *App) void {
    app.fx.publishParams(makeFxParams(app.fxp));
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

/// `FxParams` の f32 field へ comptime dispatch で書き込む（`set_fx_param` 汎用 setter）。
fn setFxParamsF32(p: *FxParams, name: []const u8, value: f32) error{UnknownParam}!void {
    inline for (@typeInfo(FxParams).@"struct".fields) |f| {
        if (f.type == f32 and std.mem.eql(u8, f.name, name)) {
            @field(p, f.name) = value;
            return;
        }
    }
    return error.UnknownParam;
}

fn waveIdxOf(name: []const u8) ?usize {
    for (WAVE_NAMES, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

fn actionSetParam(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const nf = try actions.parseNameF32(args);
    try setParamsF32(&app.params, nf.name, nf.value);
    republishPatch(app);
    return "ok";
}

fn actionSetWave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const name = try actions.parseName(args);
    app.params.wave_idx = waveIdxOf(name) orelse return error.UnknownWave;
    republishPatch(app);
    return "ok";
}

fn actionSetOsc2Wave(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const name = try actions.parseName(args);
    app.params.osc2_wave_idx = waveIdxOf(name) orelse return error.UnknownWave;
    republishPatch(app);
    return "ok";
}

fn actionSetFilter(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const name = try actions.parseName(args);
    const fm = std.meta.stringToEnum(dsp.FilterMode, name) orelse return error.UnknownFilter;
    app.params.filter_mode_idx = @intFromEnum(fm); // filterModeOf の switch 順と同じ ordinal
    republishPatch(app);
    return "ok";
}

fn actionSetFxParam(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const nf = try actions.parseNameF32(args);
    try setFxParamsF32(&app.fxp, nf.name, nf.value);
    republishFx(app);
    return "ok";
}

fn actionSetFxBypass(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    app.fxp.bypass = try actions.parseBool01(args);
    republishFx(app);
    return "ok";
}

/// 6 action を一括登録する（`platform.init()` 後・main loop 前に呼ぶ。harness 無効時は
/// `registerAction` 自体が no-op なので通常実行に影響しない）。
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "set_param", .ctx = app, .run = actionSetParam });
    platform.registerAction(.{ .name = "set_wave", .ctx = app, .run = actionSetWave });
    platform.registerAction(.{ .name = "set_osc2_wave", .ctx = app, .run = actionSetOsc2Wave });
    platform.registerAction(.{ .name = "set_filter", .ctx = app, .run = actionSetFilter });
    platform.registerAction(.{ .name = "set_fx_param", .ctx = app, .run = actionSetFxParam });
    platform.registerAction(.{ .name = "set_fx_bypass", .ctx = app, .run = actionSetFxBypass });
}
