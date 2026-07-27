//! apps/synth — the synthesiser app.
//!
//! Input: PC keyboard (A..K = C4..C5) and on-screen GUI keyboard (click).
//! Controls: GUI sliders/buttons change timbre (osc/filter/env/LFO/unison/osc2/noise) and master FX (delay/chorus/dist/reverb).
//! Display: output tap → mono downmix → spectrogram / oscilloscope / peak·RMS level meter.
//! Audio runs from the L1 audio RT callback through Synth.render→MasterEffects.process (GUI⇔Audio is lock-free).

const std = @import("std");
const kit = @import("kit"); // Public umbrella (ADR-007 R4/R5: apps are kit-only consumers)
const platform = kit.platform;
const audio = kit.audio;
const synthlib = kit.synth;
const dsp = kit.dsp;
const gui = kit.gui;
const app_runtime = kit.app_runtime;
const spectrogram = @import("spectrogram");
const scope = @import("scope");
const actions = @import("actions.zig");
const patch_io = @import("patch_io.zig");

const MAX_VOICES = 16;
const Synth = synthlib.Synth(MAX_VOICES);
const Tap = synthlib.SampleTap(8192);
const Patch = synthlib.Patch;
// Master effects: delay ~1.36s (65536@48k) / chorus ~85ms (4096@48k, headroom at 96kHz). Both powers of two.
const Fx = synthlib.MasterEffects(65536, 4096);

const NOTE_LOW = 60; // C4
const NOTE_HIGH = 72; // C5
const NOTE_COUNT = NOTE_HIGH - NOTE_LOW + 1;

// Layout (control panel is 4 columns. The FX column is 11 rows tall, so leave vertical room)
// Visualisation strip (y 300..420, h 120) split horizontally: spectrogram / oscilloscope / level meter.
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
const VIS_Y0 = 300; // Top of the visualisation strip (shared by SPEC/SCOPE/METER)
const VIS_H = 120;
const PIANO_Y0 = 440;
const PIANO_H = 55;

const Spec = spectrogram.Spectrogram(SPEC_W, SPEC_H);
const Scope = scope.Oscilloscope(SCOPE_W, VIS_H);

/// App state (driven via app_runtime: native behaviour unchanged + wasm export driven).
const App = struct {
    /// Initial window spec consulted by app_runtime
    pub const window = .{
        .w = WIN_W,
        .h = WIN_H,
        .title = "synth - keyboard + sliders + spectrogram",
    };

    gpa: std.mem.Allocator,
    /// File I/O handle used by the `save_patch`/`load_patch` actions
    /// (`std.process.Init.io`. Event-time only; never passed onto the RT path).
    io: std.Io,
    synth: Synth,
    fx: Fx,
    /// GUI-side copy of the last published patch (for the patch probe.
    /// Do not touch Mailbox consumer state from the probe — it is RT-exclusive)
    last_patch: Patch = .{},
    tap: Tap = .{},
    /// Parameter bundle updated in-place by GUI sliders/buttons
    params: Params = .{},
    fxp: FxParams = .{},
    device: audio.AudioDevice,
    ctx: gui.Context,
    /// System OutlineFont for the GUI (falls back to default_font when not found).
    gui_font: kit.GuiFont = .{},
    spec: *Spec,
    osc: *Scope,
    meter: scope.LevelMeter = .{},
    pressed: [128]bool = [_]bool{false} ** 128,
    mouse_note: ?u8 = null,
    stereo: [2048]f32 = undefined,
    mono: [1024]f32 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !*App {
        return appInit(gpa, io);
    }
    pub fn deinit(self: *App) void {
        appDeinit(self);
    }
    pub fn frame(self: *App, win: *platform.Window, now: f64) !bool {
        _ = now; // Pacing is owned by app_runtime. synth does not use the timestamp.
        return appFrame(self, win);
    }
};

fn audioCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const app: *App = @ptrCast(@alignCast(userdata.?));
    app.synth.render(buf, frames, channels);
    app.fx.process(buf, frames, channels); // Master effects (before the output tap)
    app.tap.write(buf);
}

fn keyToNote(key: platform.KeyCode) ?u8 {
    return switch (key) {
        .A => 60,
        .W => 61,
        .S => 62,
        .E => 63,
        .D => 64,
        .F => 65,
        .T => 66,
        .G => 67,
        .Y => 68,
        .H => 69,
        .U => 70,
        .J => 71,
        .K => 72,
        else => null,
    };
}

/// Hit-test for the on-screen keyboard. Returns the note number from x,y inside the piano region.
fn pianoHitTest(x: i32, y: i32) ?u8 {
    if (y < PIANO_Y0 or y >= PIANO_Y0 + PIANO_H) return null;
    if (x < 0 or x >= WIN_W) return null;
    const idx = @as(usize, @intCast(x)) * NOTE_COUNT / WIN_W;
    return @intCast(NOTE_LOW + idx);
}

/// framebuffer pixel u32 packing (same as gui.Color: memory B,G,R,A = u32 0xAARRGGBB).
fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return @as(u32, b) | (@as(u32, g) << 8) | (@as(u32, r) << 16) | (@as(u32, a) << 24);
}

fn drawSpectrogramBgAndPiano(fb: platform.Framebuffer, pressed: *const [128]bool) void {
    const w: usize = fb.width;
    const h: usize = fb.height;
    @memset(fb.pixels, rgba(0x10, 0x10, 0x18, 0xFF)); // Dark background

    // On-screen keyboard (bottom). Distinguishes white/black keys; highlights while pressed.
    var note: usize = NOTE_LOW;
    while (note <= NOTE_HIGH) : (note += 1) {
        const idx = note - NOTE_LOW;
        const x0 = idx * w / NOTE_COUNT;
        const x1 = (idx + 1) * w / NOTE_COUNT;
        const semitone = note % 12;
        const is_black = (semitone == 1 or semitone == 3 or semitone == 6 or semitone == 8 or semitone == 10);
        const base: u32 = if (is_black) rgba(0x30, 0x30, 0x38, 0xFF) else rgba(0xC8, 0xC8, 0xD0, 0xFF);
        const lit: u32 = rgba(0xFF, 0xC0, 0x40, 0xFF); // Pressed (amber)
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

/// Overlay log-frequency labels (inner left) and a dB colour-scale legend (gap under the strip) on the spectrogram.
fn drawSpecLabels(fb: platform.Framebuffer, spec: *const Spec) void {
    const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
    const clip: gui.Rect = .{ .x = 0, .y = 0, .w = @intCast(fb.width), .h = @intCast(fb.height) };
    const label_col = gui.Color.rgba(0xE0, 0xE0, 0xE0, 0xFF);
    const tick_col = rgba(0xFF, 0xFF, 0xFF, 0xFF);

    // Frequency labels (log-axis positions). tick is the true position; text y is clamped into the region.
    const ty_min: i32 = SPEC_Y0;
    const ty_max: i32 = SPEC_Y0 + SPEC_H - 16; // Reserve 16 px at the top for font height
    for (FREQ_LABELS) |fl| {
        const off = spec.rowOffsetForFreq(fl.hz) orelse continue;
        const tick_y = SPEC_Y0 + off;
        var tx: usize = SPEC_X0;
        while (tx < SPEC_X0 + 6) : (tx += 1) putFb(fb, tx, tick_y, tick_col);
        const ty = std.math.clamp(@as(i32, @intCast(tick_y)) - 8, ty_min, ty_max);
        gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0 + 8, .y = ty }, fl.text, label_col, clip, 1.0);
    }

    // dB colour-scale legend (under the strip, y=420..440): "-60dB" [horizontal gradient] "0dB"
    const leg_y = SPEC_Y0 + SPEC_H + 2; // 422
    const bar_x0 = SPEC_X0 + 56; // To the right of "-60dB" (5 chars = 40px)
    const bar_w: usize = 160;
    const bar_y = leg_y + 2;
    const bar_h: usize = 10;
    gui.default_bitmap_font.drawTo(target, .{ .x = SPEC_X0, .y = leg_y }, "-60dB", label_col, clip, 1.0);
    var lx: usize = 0;
    while (lx < bar_w) : (lx += 1) {
        const v: u8 = @intCast(lx * 255 / (bar_w - 1));
        const c = spectrogram.intensityColor(v);
        var ly: usize = 0;
        while (ly < bar_h) : (ly += 1) putFb(fb, bar_x0 + lx, bar_y + ly, c);
    }
    gui.default_bitmap_font.drawTo(target, .{ .x = bar_x0 + bar_w + 6, .y = leg_y }, "0dB", label_col, clip, 1.0);
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
// Custom probes for the headless verification harness
//
// Opt-in via `platform.registerProbe`. The framework routes raw+digest without interpreting the payload.
// ctx is *App. voices/patch are updated by the audio RT thread, so main-thread reads may be torn
// best-effort snapshot (same debug policy as the existing audio probe). Do not add sync/alloc/lock on the RT path.
// ============================================================================

/// Format VoicePool occupancy as one JSON line (list note/stage of active voices).
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

/// Format the published patch as one JSON line.
/// Read the GUI-side copy (last_patch) so the Mailbox consumer state (RT-exclusive) is never touched.
/// The probe shares the GUI thread (main), so a plain read is safe.
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

fn appInit(gpa: std.mem.Allocator, io: std.Io) !*App {
    const app = try gpa.create(App);
    errdefer gpa.destroy(app);

    const initial_patch = makePatch(Params{});
    const spec = try gpa.create(Spec);
    errdefer gpa.destroy(spec);
    spec.init(48000); // Provisional sr. After audio.open, setSampleRate recalculates the log axis

    const osc = try gpa.create(Scope);
    errdefer gpa.destroy(osc);
    osc.* = .{};

    // device is opened later. Avoid leaving it undefined; write it after a successful open.
    app.* = .{
        .gpa = gpa,
        .io = io,
        .synth = Synth.init(48000, initial_patch),
        .fx = Fx.init(48000, makeFxParams(FxParams{})),
        .last_patch = initial_patch,
        .device = undefined,
        .ctx = gui.Context.init(gpa, gui.default_font),
        .spec = spec,
        .osc = osc,
    };
    errdefer app.ctx.deinit();

    // After App is finally placed, load GuiFont in-place and re-point ctx.font.
    app.gui_font.load(io, gpa);
    errdefer app.gui_font.deinit();
    app.ctx.font = app.gui_font.asFont();

    const device = audio.open(gpa, .{
        .sample_rate = 48000,
        .buffer_frames = 512,
        .channels = 2,
        .render_callback = audioCallback,
        .userdata = app,
    }) catch |err| {
        std.debug.print("audio.open failed: {s}\n", .{@errorName(err)});
        return err;
    };
    app.device = device;

    const sr: f32 = @floatFromInt(device.config().sample_rate);
    app.synth.sample_rate = sr;
    app.fx.setSampleRate(sr);
    app.spec.setSampleRate(sr);

    device.start() catch |err| {
        app.device.close();
        std.debug.print("audio.start failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // harness custom probe / action (no-op when disabled)
    platform.registerProbe(.{ .name = "voices", .ctx = app, .ext = "json", .snapshot = voicesSnapshot, .digest = voicesDigest });
    platform.registerProbe(.{ .name = "patch", .ctx = app, .ext = "json", .snapshot = patchSnapshot, .digest = patchDigest });
    registerActions(app);
    registerStateSync(app);

    return app;
}

fn appDeinit(self: *App) void {
    self.device.stop();
    self.device.close();
    self.ctx.deinit();
    self.gui_font.deinit();
    self.gpa.destroy(self.osc);
    self.gpa.destroy(self.spec);
    self.gpa.destroy(self);
}

fn appFrame(self: *App, window: *platform.Window) !bool {
    var running = true;
    // Pacing is owned by app_runtime (waits once after returning from `app.frame` and unlocking the framebuffer).
    const fb = window.lockFramebuffer() orelse return true; // No frame slot (retry allowed)
    defer fb.unlock();

    self.ctx.beginFrame(fb.width, fb.height);

    while (window.nextEvent()) |ev| {
        switch (ev) {
            .quit => running = false,
            .key_down => |k| {
                if (k.key == .ESCAPE) {
                    running = false;
                } else if (keyToNote(k.key)) |note| {
                    if (!k.is_repeat and !self.pressed[note]) {
                        self.pressed[note] = true;
                        _ = self.synth.sendNoteOn(note, 1.0);
                    }
                }
            },
            .key_up => |k| {
                if (keyToNote(k.key)) |note| {
                    if (self.pressed[note]) {
                        self.pressed[note] = false;
                        _ = self.synth.sendNoteOff(note);
                    }
                }
            },
            .mouse_down => |m| {
                if (pianoHitTest(m.x, m.y)) |note| {
                    self.mouse_note = note;
                    if (!self.pressed[note]) {
                        self.pressed[note] = true;
                        _ = self.synth.sendNoteOn(note, 1.0);
                    }
                }
            },
            .mouse_up => {
                if (self.mouse_note) |note| {
                    self.pressed[note] = false;
                    _ = self.synth.sendNoteOff(note);
                    self.mouse_note = null;
                }
            },
            else => {},
        }
        if (toGuiEvent(ev)) |ge| self.ctx.pushEvent(ge);
    }

    // Drain the output tap → mono downmix → spectrogram / oscilloscope / level meter
    while (true) {
        const n = self.tap.read(&self.stereo);
        if (n < 2) break;
        const frames = n / 2;
        dsp.downmixStereoToMono(self.stereo[0 .. frames * 2], self.mono[0..frames]);
        self.spec.feed(self.mono[0..frames]);
        self.osc.feed(self.mono[0..frames]);
        self.meter.feed(self.mono[0..frames]);
    }

    // GUI control panel (top)
    self.ctx.beginBox(.{
        .direction = .column,
        .padding = .{ 10, 10, 10, 10 },
        .gap = 6,
        .bg = gui.Color.rgba(0x20, 0x24, 0x2C, 0xFF),
    });
    self.ctx.label("Synth controls (drag knobs):");
    self.ctx.beginBox(.{ .direction = .row, .gap = 18 });
    self.ctx.beginBox(.{ .direction = .column, .gap = 4 });
    _ = self.ctx.sliderF32Id(0x6001, "Cutoff   ", &self.params.cutoff, .{ .min = 100, .max = 18000, .step = 10 });
    _ = self.ctx.sliderF32Id(0x6002, "Resonance", &self.params.resonance, .{ .min = 0.5, .max = 8, .step = 0.1 });
    _ = self.ctx.sliderF32Id(0x6003, "Gain     ", &self.params.gain, .{ .min = 0, .max = 0.5, .step = 0.01 });
    _ = self.ctx.sliderF32Id(0x6004, "Attack   ", &self.params.attack, .{ .min = 0, .max = 1, .step = 0.01 });
    _ = self.ctx.sliderF32Id(0x6005, "Release  ", &self.params.release, .{ .min = 0.01, .max = 2, .step = 0.01 });
    _ = self.ctx.sliderF32Id(0x6006, "KeyTrack ", &self.params.keytrack, .{ .min = 0, .max = 1, .step = 0.05 });
    self.ctx.endBox();
    self.ctx.beginBox(.{ .direction = .column, .gap = 4 });
    _ = self.ctx.sliderF32Id(0x6007, "FiltEnv  ", &self.params.filter_env_amount, .{ .min = 0, .max = 5, .step = 0.1 });
    _ = self.ctx.sliderF32Id(0x6008, "FEnvAtk  ", &self.params.filter_attack, .{ .min = 0, .max = 1, .step = 0.01 });
    _ = self.ctx.sliderF32Id(0x6009, "FEnvDec  ", &self.params.filter_decay, .{ .min = 0.01, .max = 1, .step = 0.01 });
    _ = self.ctx.sliderF32Id(0x600A, "LFO Rate ", &self.params.lfo_rate, .{ .min = 0.1, .max = 20, .step = 0.1 });
    _ = self.ctx.sliderF32Id(0x600B, "Vibrato  ", &self.params.vibrato_depth, .{ .min = 0, .max = 2, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x600C, "Tremolo  ", &self.params.tremolo_depth, .{ .min = 0, .max = 1, .step = 0.05 });
    self.ctx.endBox();
    self.ctx.beginBox(.{ .direction = .column, .gap = 4 });
    _ = self.ctx.sliderF32Id(0x600D, "Unison   ", &self.params.unison, .{ .min = 1, .max = 7, .step = 1 });
    _ = self.ctx.sliderF32Id(0x600E, "Detune   ", &self.params.detune, .{ .min = 0, .max = 50, .step = 1 });
    _ = self.ctx.sliderF32Id(0x600F, "Osc2 Mix ", &self.params.osc2_mix, .{ .min = 0, .max = 1, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x6010, "Osc2 Det ", &self.params.osc2_detune, .{ .min = -24, .max = 24, .step = 1 });
    _ = self.ctx.sliderF32Id(0x6011, "Noise    ", &self.params.noise_amount, .{ .min = 0, .max = 1, .step = 0.05 });
    self.ctx.endBox();
    self.ctx.beginBox(.{ .direction = .column, .gap = 4 });
    _ = self.ctx.sliderF32Id(0x6012, "Dly Time ", &self.fxp.delay_time, .{ .min = 0.01, .max = 1.0, .step = 0.01 });
    _ = self.ctx.sliderF32Id(0x6013, "Dly FB   ", &self.fxp.delay_fb, .{ .min = 0, .max = 0.95, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x6014, "Dly Mix  ", &self.fxp.delay_mix, .{ .min = 0, .max = 1, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x6015, "Cho Rate ", &self.fxp.chorus_rate, .{ .min = 0.1, .max = 8, .step = 0.1 });
    _ = self.ctx.sliderF32Id(0x6016, "Cho Depth", &self.fxp.chorus_depth, .{ .min = 0.5, .max = 10, .step = 0.5 });
    _ = self.ctx.sliderF32Id(0x6017, "Cho Mix  ", &self.fxp.chorus_mix, .{ .min = 0, .max = 1, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x6018, "Dist Drv ", &self.fxp.dist_drive, .{ .min = 1, .max = 20, .step = 0.5 });
    _ = self.ctx.sliderF32Id(0x6019, "Dist Mix ", &self.fxp.dist_mix, .{ .min = 0, .max = 1, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x601A, "Rev Mix  ", &self.fxp.reverb_mix, .{ .min = 0, .max = 1, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x601B, "Rev Decay", &self.fxp.reverb_decay, .{ .min = 0, .max = 1, .step = 0.05 });
    _ = self.ctx.sliderF32Id(0x601C, "Rev Damp ", &self.fxp.reverb_damping, .{ .min = 0, .max = 1, .step = 0.05 });
    self.ctx.endBox();
    self.ctx.endBox();
    self.ctx.beginBox(.{ .direction = .row, .gap = 8 });
    const wlabel = std.fmt.allocPrint(self.ctx.allocator(), "Wave: {s}", .{WAVE_NAMES[self.params.wave_idx]}) catch "Wave";
    if (self.ctx.button(wlabel)) self.params.wave_idx = (self.params.wave_idx + 1) % WAVE_NAMES.len;
    const flabel = std.fmt.allocPrint(self.ctx.allocator(), "Filter: {s}", .{FILTER_MODE_NAMES[self.params.filter_mode_idx]}) catch "Filter";
    if (self.ctx.button(flabel)) self.params.filter_mode_idx = (self.params.filter_mode_idx + 1) % FILTER_MODE_NAMES.len;
    const o2label = std.fmt.allocPrint(self.ctx.allocator(), "Osc2: {s}", .{WAVE_NAMES[self.params.osc2_wave_idx]}) catch "Osc2";
    if (self.ctx.button(o2label)) self.params.osc2_wave_idx = (self.params.osc2_wave_idx + 1) % WAVE_NAMES.len;
    const fxlabel = if (self.fxp.bypass) "FX: off" else "FX: on";
    if (self.ctx.button(fxlabel)) self.fxp.bypass = !self.fxp.bypass;
    self.ctx.endBox();
    self.ctx.endBox();
    self.ctx.endFrame();

    // Publish parameters (to the audio thread via atomic/patch publish)
    self.last_patch = makePatch(self.params);
    self.synth.publishPatch(self.last_patch);
    self.fx.publishParams(makeFxParams(self.fxp));

    // Manual draw → GUI
    drawSpectrogramBgAndPiano(fb, &self.pressed);
    self.spec.draw(fb.pixels, fb.width, fb.height, SPEC_X0, SPEC_Y0);
    self.osc.draw(fb.pixels, fb.width, fb.height, SCOPE_X0, VIS_Y0);
    self.meter.draw(fb.pixels, fb.width, fb.height, METER_X0, VIS_Y0, METER_W, VIS_H);
    drawSpecLabels(fb, self.spec);
    const target: gui.RenderTarget = .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height };
    gui.render(target, &self.ctx.draw_list, self.ctx.font, 1.0);

    window.present();
    // Pacing is owned by app_runtime (wasm is paced by rAF, so no pacing here).
    return running;
}

const Rt = app_runtime.Runtime(App);

pub fn enableWasmRuntime() void {
    Rt.enableWasmExports();
    // Keep audio_web exports (vp_audio_render / stack_top / render_buf) alive against DCE
    audio.enableWebAudioExports();
}

pub fn main(process_init: std.process.Init) !void {
    std.debug.print("apps/synth: A..K=C4..C5 / click the on-screen keys / sliders change the timbre / ESC quits\n", .{});
    try Rt.runNative(process_init);
}

/// Parameter bundle updated in-place by GUI sliders/buttons.
const Params = struct {
    cutoff: f32 = 6000,
    resonance: f32 = 1.2,
    gain: f32 = 0.2,
    attack: f32 = 0.01,
    release: f32 = 0.2,
    wave_idx: usize = 1, // saw
    filter_mode_idx: usize = 0, // lowpass
    keytrack: f32 = 0.0,
    filter_env_amount: f32 = 0.0, // Filter env amount (octaves)
    filter_attack: f32 = 0.01,
    filter_decay: f32 = 0.2,
    lfo_rate: f32 = 5.0,
    vibrato_depth: f32 = 0.0, // Semitones
    tremolo_depth: f32 = 0.0, // 0..1
    // Oscillator extensions. unison is kept as f32 for the slider and converted to u8 in makePatch.
    unison: f32 = 1,
    detune: f32 = 0.0, // cents
    osc2_mix: f32 = 0.0, // 0..1
    osc2_detune: f32 = 0.0, // Semitones
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

/// GUI parameter bundle for master effects (updated in-place).
const FxParams = struct {
    bypass: bool = false,
    delay_time: f32 = 0.25, // Seconds
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
// Custom actions for the headless verification harness (synth adopts registerAction,
// same shape as pixie: a write mouth symmetric to probe(read). Only rewrites the same
// App.params/App.fxp fields the UI does).
//
// Hot-path declaration: every action `run()` is event-time only (once per harness `action` command,
// inside main-thread pollGate). Neither per-frame nor per-sample, so the performance rules do not apply.
// State propagation uses the existing RT-safe cross-thread hand-off (`Synth.publishPatch` /
// `MasterEffects.publishParams`; both go through atomic/Mailbox, identical to the existing code
// path the GUI calls every frame). On the RT path (`Synth.render`/`MasterEffects.process`) no new
// sync/alloc/lock/panic is added.
//
// Parsers live in `actions.zig` (std only; no App/kit/dsp) and are unit-tested there. Enum-name
// resolution (wave/filter name → index) stays in this file, which knows App's concrete types
// (same separation as pixie's `ToolKind` resolution).
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

/// Write a `Params` f32 field via comptime dispatch (generic `set_param` setter).
fn setParamsF32(p: *Params, name: []const u8, value: f32) error{UnknownParam}!void {
    inline for (@typeInfo(Params).@"struct".fields) |f| {
        if (f.type == f32 and std.mem.eql(u8, f.name, name)) {
            @field(p, f.name) = value;
            return;
        }
    }
    return error.UnknownParam;
}

/// Write an `FxParams` f32 field via comptime dispatch (generic `set_fx_param` setter).
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
    app.params.filter_mode_idx = @intFromEnum(fm); // Same ordinal as the switch order in filterModeOf
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

// ============================================================================
// save_patch / load_patch (persistence mouth symmetric to the `patch` probe).
//
// Hot-path declaration: save/load is event-time only (once per action. Blocking std.Io file I/O
// finishes inside main-thread pollGate). Never touches the RT path (Synth.render/MasterEffects.process).
// Persist only App.params/App.fxp (the same values as the GUI sliders). After load, republish via
// the existing republishPatch/republishFx path (atomic/Mailbox) onto the audio thread.
// ============================================================================

fn actionSavePatch(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    try patch_io.save(app.io, path, Params, FxParams, app.params, app.fxp, app.gpa);
    return "ok";
}

fn actionLoadPatch(ctx: *anyopaque, args: []const u8, buf: []u8) anyerror![]const u8 {
    _ = buf;
    const app = actionApp(ctx);
    const path = try actions.parsePath(args);
    const loaded = try patch_io.load(app.io, app.gpa, path, Params, FxParams);
    app.params = loaded.params;
    app.fxp = loaded.fxp;
    republishPatch(app);
    republishFx(app);
    return "ok";
}

/// Register all 8 actions in one go (call after `platform.init()`, before the main loop. When the harness
/// is disabled `registerAction` itself is a no-op, so normal runs are unaffected).
fn registerActions(app: *App) void {
    platform.registerAction(.{ .name = "set_param", .ctx = app, .run = actionSetParam });
    platform.registerAction(.{ .name = "set_wave", .ctx = app, .run = actionSetWave });
    platform.registerAction(.{ .name = "set_osc2_wave", .ctx = app, .run = actionSetOsc2Wave });
    platform.registerAction(.{ .name = "set_filter", .ctx = app, .run = actionSetFilter });
    platform.registerAction(.{ .name = "set_fx_param", .ctx = app, .run = actionSetFxParam });
    platform.registerAction(.{ .name = "set_fx_bypass", .ctx = app, .run = actionSetFxBypass });
    platform.registerAction(.{ .name = "save_patch", .ctx = app, .run = actionSavePatch });
    platform.registerAction(.{ .name = "load_patch", .ctx = app, .run = actionLoadPatch });
}

fn netsyncExport(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    const app = actionApp(ctx);
    return patch_io.encode(Params, FxParams, allocator, app.params, app.fxp);
}

fn netsyncImport(ctx: *anyopaque, bytes: []const u8) anyerror!void {
    const app = actionApp(ctx);
    const loaded = try patch_io.decode(Params, FxParams, bytes);
    app.params = loaded.params;
    app.fxp = loaded.fxp;
    republishPatch(app);
    republishFx(app);
}

fn registerStateSync(app: *App) void {
    platform.registerStateSync(.{
        .ctx = app,
        .export_fn = netsyncExport,
        .import_fn = netsyncImport,
    });
}
