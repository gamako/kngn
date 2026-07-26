//! SoundPlayer — fixed-slot SE one-shots + one BGM loop, in-memory playback mixer.
//!
//! Hot-path note (RT / every sample):
//! - Only fixed-slot / BGM sample reads, adds, and gain multiplies.
//! - No alloc / lock / IO / panic / per-sample transcendentals / WAV decode / resample.
//! - Command drain and bus-gain acquire loads happen only at the start of a block.
//! - Pan trig functions are computed once in playSound (main thread).

const std = @import("std");
const synth = @import("synth");
const dsp = @import("dsp");

pub const Sound = struct {
    /// f32 interleaved samples (owned by the caller; player keeps a view only).
    ///
    /// Precondition: every sample is finite (`decodeWav` already guarantees this).
    /// Does not scan-validate all samples (API-boundary contract).
    samples: []const f32,
    sample_rate: u32,
    channels: u16,
};

pub const Error = error{
    SampleRateMismatch,
    UnsupportedChannel,
    /// gain / pan is non-finite (NaN / ±Inf).
    InvalidParameter,
    CommandQueueFull,
    OutOfMemory,
};

const Command = union(enum) {
    play_sound: struct {
        sound: *const Sound,
        gain: f32,
        pan_l: f32,
        pan_r: f32,
    },
    stop_all_se: void,
    set_bgm: ?*const Sound,
    stop_bgm: void,
};

const Slot = struct {
    active: bool = false,
    sound: *const Sound = undefined,
    /// Playback frame position (interleaved frame index).
    pos: usize = 0,
    gain: f32 = 1.0,
    pan_l: f32 = 1.0,
    pan_r: f32 = 1.0,
    /// Start order (smaller = older; used for slot steal).
    start_order: u64 = 0,
};

const BgmState = struct {
    active: bool = false,
    sound: *const Sound = undefined,
    pos: usize = 0,
};

/// SE + BGM mixer with a comptime-fixed slot count.
pub fn SoundPlayer(comptime slot_count: usize) type {
    return struct {
        const Self = @This();
        const Ring = synth.SpscRing(Command, 64);

        allocator: std.mem.Allocator,
        /// Device sample rate allowed for playback (fixed at create; mismatch refused at play).
        sample_rate: u32,

        slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,
        bgm: BgmState = .{},
        /// Monotonic counter for slot steal.
        /// u64 effectively does not wrap (even at 1000/sec ≈ 5.8e8 years). On wrap, oldest selection
        /// is wrong once; no real harm.
        next_start_order: u64 = 1,

        // SPSC command ring (head/tail already cache_line-separated inside the ring)
        commands: Ring = .{},

        // Bus gains — each atomic on its own cache line (avoid false sharing)
        master_gain: synth.AtomicF32 align(std.atomic.cache_line) = synth.AtomicF32.init(1.0),
        se_gain: synth.AtomicF32 align(std.atomic.cache_line) = synth.AtomicF32.init(1.0),
        bgm_gain: synth.AtomicF32 align(std.atomic.cache_line) = synth.AtomicF32.init(1.0),

        /// sample_rate / channels mismatch observed on the RT path. Main reads via `isMismatchDetected`.
        /// RT must not log / panic, so only a flag is set.
        mismatch_detected: std.atomic.Value(bool) align(std.atomic.cache_line) = std.atomic.Value(bool).init(false),

        pub fn create(allocator: std.mem.Allocator, sample_rate: u32) Error!*Self {
            const self = allocator.create(Self) catch return error.OutOfMemory;
            self.* = .{
                .allocator = allocator,
                .sample_rate = sample_rate,
            };
            return self;
        }

        /// Call only after the audio device has stopped.
        pub fn destroy(self: *Self) void {
            const a = self.allocator;
            a.destroy(self);
        }

        // ---- main thread API ----

        /// Master bus gain. Non-finite (NaN / ±Inf) is ignored; current value kept.
        pub fn setMasterGain(self: *Self, g: f32) void {
            if (!std.math.isFinite(g)) return;
            self.master_gain.store(g);
        }
        /// SE bus gain. Non-finite is ignored; current value kept.
        pub fn setSeGain(self: *Self, g: f32) void {
            if (!std.math.isFinite(g)) return;
            self.se_gain.store(g);
        }
        /// BGM bus gain. Non-finite is ignored; current value kept.
        pub fn setBgmGain(self: *Self, g: f32) void {
            if (!std.math.isFinite(g)) return;
            self.bgm_gain.store(g);
        }

        /// SE one-shot. pan is -1(left)..0(center)..+1(right). Stereo sources ignore pan.
        /// Non-finite gain / pan → `error.InvalidParameter` (does not play).
        pub fn playSound(self: *Self, sound: *const Sound, gain: f32, pan: f32) Error!void {
            if (!std.math.isFinite(gain) or !std.math.isFinite(pan)) return error.InvalidParameter;
            try self.validateSound(sound);
            const stereo = dsp.equalPowerPan(pan);
            if (!self.commands.push(.{ .play_sound = .{
                .sound = sound,
                .gain = gain,
                .pan_l = stereo.l,
                .pan_r = stereo.r,
            } })) return error.CommandQueueFull;
        }

        pub fn stopAllSe(self: *Self) Error!void {
            if (!self.commands.push(.{ .stop_all_se = {} })) return error.CommandQueueFull;
        }

        pub fn setBgm(self: *Self, sound: ?*const Sound) Error!void {
            if (sound) |s| try self.validateSound(s);
            if (!self.commands.push(.{ .set_bgm = sound })) return error.CommandQueueFull;
        }

        pub fn stopBgm(self: *Self) Error!void {
            if (!self.commands.push(.{ .stop_bgm = {} })) return error.CommandQueueFull;
        }

        /// Whether RT detected a sample_rate / channels mismatch (acquire).
        pub fn isMismatchDetected(self: *const Self) bool {
            return self.mismatch_detected.load(.acquire);
        }

        /// Clear the diagnostic flag (main thread; stays false until the next mismatch).
        pub fn clearMismatchDetected(self: *Self) void {
            self.mismatch_detected.store(false, .release);
        }

        fn validateSound(self: *const Self, sound: *const Sound) Error!void {
            if (sound.sample_rate != self.sample_rate) return error.SampleRateMismatch;
            if (sound.channels != 1 and sound.channels != 2) return error.UnsupportedChannel;
            if (sound.samples.len == 0) return error.UnsupportedChannel;
            if (sound.samples.len % @as(usize, sound.channels) != 0) return error.UnsupportedChannel;
        }

        // ---- RT: audio callback ----

        /// Called from the audio render callback. `buf` is interleaved, length `frames * channels`.
        ///
        /// Output channels: 1 = mono (stereo source downmixes (L+R)*0.5), 2 = stereo.
        /// When `sample_rate != create-time SR` / `channels == 0` / `channels > 2`,
        /// zero-fill (channels==0 is a no-op: nowhere to write) and return immediately,
        /// setting `mismatch_detected` (no panic / log on the RT path).
        pub fn render(self: *Self, buf: []f32, frames: u32, channels: u32, sample_rate: u32) void {
            if (sample_rate != self.sample_rate or channels == 0 or channels > 2) {
                self.mismatch_detected.store(true, .release);
                // channels==0: no-op (nowhere to write). Otherwise zero-fill what we can.
                if (channels > 0) {
                    const n = @as(usize, frames) * @as(usize, channels);
                    const fill_n = @min(n, buf.len);
                    if (fill_n > 0) @memset(buf[0..fill_n], 0);
                }
                return;
            }

            const n = @as(usize, frames) * @as(usize, channels);
            const fill_n = @min(n, buf.len);
            if (fill_n > 0) @memset(buf[0..fill_n], 0);

            // Block start: drain all commands + load bus gains once
            self.drainCommands();
            const master = self.master_gain.load();
            const se_bus = self.se_gain.load();
            const bgm_bus = self.bgm_gain.load();
            const se_scale = master * se_bus;
            const bgm_scale = master * bgm_bus;

            // SE slots
            for (&self.slots) |*slot| {
                if (!slot.active) continue;
                self.renderSlot(slot, buf, frames, channels, se_scale);
            }

            // BGM loop
            if (self.bgm.active) {
                self.renderBgm(buf, frames, channels, bgm_scale);
            }
        }

        fn drainCommands(self: *Self) void {
            while (self.commands.pop()) |cmd| {
                switch (cmd) {
                    .play_sound => |ps| self.startSe(ps.sound, ps.gain, ps.pan_l, ps.pan_r),
                    .stop_all_se => {
                        for (&self.slots) |*s| s.active = false;
                    },
                    .set_bgm => |maybe| {
                        if (maybe) |s| {
                            self.bgm = .{ .active = true, .sound = s, .pos = 0 };
                        } else {
                            self.bgm.active = false;
                        }
                    },
                    .stop_bgm => self.bgm.active = false,
                }
            }
        }

        fn startSe(self: *Self, sound: *const Sound, gain: f32, pan_l: f32, pan_r: f32) void {
            const idx = self.pickSlot();
            self.slots[idx] = .{
                .active = true,
                .sound = sound,
                .pos = 0,
                .gain = gain,
                .pan_l = pan_l,
                .pan_r = pan_r,
                .start_order = self.next_start_order,
            };
            self.next_start_order +%= 1;
        }

        /// 1. smallest inactive index  2. if all active, oldest start_order  3. tie → smallest index
        fn pickSlot(self: *const Self) usize {
            var free_idx: ?usize = null;
            var i: usize = 0;
            while (i < slot_count) : (i += 1) {
                if (!self.slots[i].active) {
                    free_idx = i;
                    break;
                }
            }
            if (free_idx) |fi| return fi;

            var best: usize = 0;
            var best_order = self.slots[0].start_order;
            i = 1;
            while (i < slot_count) : (i += 1) {
                const o = self.slots[i].start_order;
                if (o < best_order or (o == best_order and i < best)) {
                    best = i;
                    best_order = o;
                }
            }
            return best;
        }

        fn renderSlot(self: *Self, slot: *Slot, buf: []f32, frames: u32, channels: u32, se_scale: f32) void {
            _ = self;
            const sound = slot.sound;
            const ch: usize = sound.channels;
            const frame_count = sound.samples.len / ch;
            const g = se_scale * slot.gain;
            var f: u32 = 0;
            while (f < frames) : (f += 1) {
                if (slot.pos >= frame_count) {
                    slot.active = false;
                    break;
                }
                const out_i = @as(usize, f) * @as(usize, channels);
                if (ch == 1) {
                    const s = sound.samples[slot.pos] * g;
                    if (channels >= 2) {
                        buf[out_i] += s * slot.pan_l;
                        buf[out_i + 1] += s * slot.pan_r;
                    } else {
                        // mono out: pan_l only (center → equalPowerPan(0).l)
                        buf[out_i] += s * slot.pan_l;
                    }
                } else {
                    // stereo source: ignore pan. mono out → (L+R)*0.5 downmix
                    const base = slot.pos * 2;
                    const sl = sound.samples[base] * g;
                    const sr = sound.samples[base + 1] * g;
                    if (channels >= 2) {
                        buf[out_i] += sl;
                        buf[out_i + 1] += sr;
                    } else {
                        buf[out_i] += (sl + sr) * 0.5;
                    }
                }
                slot.pos += 1;
            }
            if (slot.pos >= frame_count) slot.active = false;
        }

        fn renderBgm(self: *Self, buf: []f32, frames: u32, channels: u32, bgm_scale: f32) void {
            const sound = self.bgm.sound;
            const ch: usize = sound.channels;
            const frame_count = sound.samples.len / ch;
            if (frame_count == 0) {
                self.bgm.active = false;
                return;
            }
            var f: u32 = 0;
            while (f < frames) : (f += 1) {
                if (self.bgm.pos >= frame_count) self.bgm.pos = 0;
                const out_i = @as(usize, f) * @as(usize, channels);
                if (ch == 1) {
                    const s = sound.samples[self.bgm.pos] * bgm_scale;
                    if (channels >= 2) {
                        buf[out_i] += s;
                        buf[out_i + 1] += s;
                    } else {
                        buf[out_i] += s;
                    }
                } else {
                    // stereo source → mono out is (L+R)*0.5 downmix
                    const base = self.bgm.pos * 2;
                    const sl = sound.samples[base] * bgm_scale;
                    const sr = sound.samples[base + 1] * bgm_scale;
                    if (channels >= 2) {
                        buf[out_i] += sl;
                        buf[out_i + 1] += sr;
                    } else {
                        buf[out_i] += (sl + sr) * 0.5;
                    }
                }
                self.bgm.pos += 1;
            }
        }
    };
}

// ============================================================================
// tests
// ============================================================================

const testing = std.testing;

const Player4 = SoundPlayer(4);
const Player2 = SoundPlayer(2);

fn monoSound(samples: []const f32, sr: u32) Sound {
    return .{ .samples = samples, .sample_rate = sr, .channels = 1 };
}
fn stereoSound(samples: []const f32, sr: u32) Sound {
    return .{ .samples = samples, .sample_rate = sr, .channels = 2 };
}

fn renderBlock(player: anytype, frames: u32) [512]f32 {
    var buf: [512]f32 = undefined;
    @memset(&buf, 0);
    const channels: u32 = 2;
    player.render(buf[0 .. frames * channels], frames, channels, player.sample_rate);
    return buf;
}

test "SoundPlayer: mono SE center / left / right pan" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();

    // 1 sample mono = 1.0
    const samples = [_]f32{1.0};
    var sound = monoSound(&samples, 48000);

    try player.playSound(&sound, 1.0, 0.0); // center
    var buf = renderBlock(player, 1);
    const c = dsp.equalPowerPan(0.0);
    try testing.expectApproxEqAbs(c.l, buf[0], 1e-5);
    try testing.expectApproxEqAbs(c.r, buf[1], 1e-5);

    try player.playSound(&sound, 1.0, -1.0); // left
    buf = renderBlock(player, 1);
    try testing.expectApproxEqAbs(@as(f32, 1.0), buf[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[1], 1e-5);

    try player.playSound(&sound, 1.0, 1.0); // right
    buf = renderBlock(player, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), buf[1], 1e-5);
}

test "SoundPlayer: stereo source ignores pan" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    // L=0.5, R=0.25
    const samples = [_]f32{ 0.5, 0.25 };
    var sound = stereoSound(&samples, 48000);

    try player.playSound(&sound, 1.0, -1.0); // pan left would zero R if applied
    const buf = renderBlock(player, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.5), buf[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25), buf[1], 1e-6);
}

test "SoundPlayer: SE one-shot start/end/polyphony" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const a = [_]f32{ 1.0, 0.5 };
    const b = [_]f32{0.25};
    var sa = monoSound(&a, 48000);
    var sb = monoSound(&b, 48000);

    try player.playSound(&sa, 1.0, 0.0);
    try player.playSound(&sb, 1.0, 0.0);
    var buf = renderBlock(player, 1);
    // both active on frame 0: 1.0 + 0.25
    const c = dsp.equalPowerPan(0.0);
    try testing.expectApproxEqAbs((1.0 + 0.25) * c.l, buf[0], 1e-5);

    buf = renderBlock(player, 1);
    // sa continues with 0.5, sb finished
    try testing.expectApproxEqAbs(0.5 * c.l, buf[0], 1e-5);

    buf = renderBlock(player, 1);
    // both done → silence
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[1], 1e-6);
}

test "SoundPlayer: oldest steal when slots full" {
    const player = try Player2.create(testing.allocator, 48000);
    defer player.destroy();
    // long tones so they stay active
    const long = [_]f32{1.0} ** 100;
    var s0 = monoSound(&long, 48000);
    var s1 = monoSound(&long, 48000);
    var s2 = monoSound(&long, 48000);

    try player.playSound(&s0, 1.0, 0.0); // slot 0, order 1
    try player.playSound(&s1, 1.0, 0.0); // slot 1, order 2
    // drain
    _ = renderBlock(player, 1);
    try testing.expect(player.slots[0].active);
    try testing.expect(player.slots[1].active);
    try testing.expectEqual(@as(u64, 1), player.slots[0].start_order);
    try testing.expectEqual(@as(u64, 2), player.slots[1].start_order);

    try player.playSound(&s2, 1.0, 0.0); // steal oldest = slot 0
    _ = renderBlock(player, 1);
    try testing.expect(player.slots[0].active);
    try testing.expectEqual(@as(u64, 3), player.slots[0].start_order);
    try testing.expectEqual(@as(u64, 2), player.slots[1].start_order);
    try testing.expect(player.slots[0].sound == &s2);
}

test "SoundPlayer: BGM loop boundary" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    // 2-frame mono pattern
    const samples = [_]f32{ 0.5, -0.5 };
    var sound = monoSound(&samples, 48000);
    try player.setBgm(&sound);

    const buf = renderBlock(player, 5);
    // frames: 0.5, -0.5, 0.5, -0.5, 0.5
    try testing.expectApproxEqAbs(@as(f32, 0.5), buf[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), buf[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), buf[4], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.5), buf[6], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), buf[8], 1e-6);
}

test "SoundPlayer: BGM switch and stop" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const a = [_]f32{1.0} ** 10;
    const b = [_]f32{0.25} ** 10;
    var sa = monoSound(&a, 48000);
    var sb = monoSound(&b, 48000);

    try player.setBgm(&sa);
    _ = renderBlock(player, 3);
    try testing.expect(player.bgm.pos == 3);

    try player.setBgm(&sb); // restart from 0
    var buf = renderBlock(player, 1);
    try testing.expectEqual(@as(usize, 1), player.bgm.pos);
    try testing.expectApproxEqAbs(@as(f32, 0.25), buf[0], 1e-6);
    try testing.expect(player.bgm.sound == &sb);

    try player.stopBgm();
    buf = renderBlock(player, 1);
    try testing.expect(!player.bgm.active);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-6);
}

test "SoundPlayer: master / SE / BGM gain accumulation" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const se_s = [_]f32{1.0};
    const bg_s = [_]f32{1.0};
    var se = monoSound(&se_s, 48000);
    var bg = monoSound(&bg_s, 48000);

    player.setMasterGain(0.5);
    player.setSeGain(0.5);
    player.setBgmGain(0.25);
    try player.playSound(&se, 1.0, 0.0); // center pan
    try player.setBgm(&bg);

    const buf = renderBlock(player, 1);
    const c = dsp.equalPowerPan(0.0);
    // SE: 0.5*0.5*1 * pan, BGM: 0.5*0.25*1 (center mono)
    const expected_l = (0.25 * c.l) + 0.125;
    const expected_r = (0.25 * c.r) + 0.125;
    try testing.expectApproxEqAbs(expected_l, buf[0], 1e-5);
    try testing.expectApproxEqAbs(expected_r, buf[1], 1e-5);
}

test "SoundPlayer: command queue full" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const samples = [_]f32{1.0};
    var sound = monoSound(&samples, 48000);
    // capacity 64
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try player.playSound(&sound, 1.0, 0.0);
    }
    try testing.expectError(error.CommandQueueFull, player.playSound(&sound, 1.0, 0.0));
}

test "SoundPlayer: SR mismatch / unsupported channel refused" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const samples = [_]f32{ 1.0, 1.0 };
    var bad_sr = monoSound(&samples, 44100);
    try testing.expectError(error.SampleRateMismatch, player.playSound(&bad_sr, 1.0, 0.0));
    try testing.expectError(error.SampleRateMismatch, player.setBgm(&bad_sr));

    var bad_ch = Sound{ .samples = &samples, .sample_rate = 48000, .channels = 3 };
    try testing.expectError(error.UnsupportedChannel, player.playSound(&bad_ch, 1.0, 0.0));
}

test "SoundPlayer: SPSC atomic cache_line separation" {
    const cl = std.atomic.cache_line;
    const P = Player4;
    try testing.expect(@alignOf(P) >= cl);
    try testing.expect(@offsetOf(P, "master_gain") % cl == 0);
    try testing.expect(@offsetOf(P, "se_gain") % cl == 0);
    try testing.expect(@offsetOf(P, "bgm_gain") % cl == 0);
    try testing.expect(@offsetOf(P, "master_gain") / cl != @offsetOf(P, "se_gain") / cl);
    try testing.expect(@offsetOf(P, "se_gain") / cl != @offsetOf(P, "bgm_gain") / cl);

    // ring head/tail separation is guaranteed by synth.SpscRing; also check via the commands field
    const Ring = synth.SpscRing(Command, 64);
    try testing.expect(@offsetOf(Ring, "head") % cl == 0);
    try testing.expect(@offsetOf(Ring, "tail") % cl == 0);
    const dist = if (@offsetOf(Ring, "tail") > @offsetOf(Ring, "head"))
        @offsetOf(Ring, "tail") - @offsetOf(Ring, "head")
    else
        @offsetOf(Ring, "head") - @offsetOf(Ring, "tail");
    try testing.expect(dist >= cl);
}

test "SoundPlayer: FailingAllocator proves RT zero-allocation + finite output" {
    // create uses a normal allocator. FailingAllocator then proves render never touches an allocator.
    // The player itself is allocated at create and render does not use self.allocator, but
    // per convention we keep a fail_index=0 FailingAllocator while driving render.
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    // Swap player.allocator and restore before destroy (render touching it would fail)
    const saved = player.allocator;
    player.allocator = failing.allocator();
    defer player.allocator = saved;

    const se_s = [_]f32{ 0.7, -0.3, 0.1 };
    const bg_s = [_]f32{ 0.2, 0.2, 0.2, 0.2 };
    var se = monoSound(&se_s, 48000);
    var bg = monoSound(&bg_s, 48000);
    try player.playSound(&se, 0.8, -0.3);
    try player.playSound(&se, 0.5, 0.5);
    try player.setBgm(&bg);

    const frames: u32 = 64;
    var buf: [128]f32 = undefined;
    var block: u32 = 0;
    while (block < 8) : (block += 1) {
        player.render(&buf, frames, 2, 48000);
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
        }
    }
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "SoundPlayer: stopAllSe" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const long = [_]f32{1.0} ** 50;
    var sound = monoSound(&long, 48000);
    try player.playSound(&sound, 1.0, 0.0);
    _ = renderBlock(player, 1);
    try testing.expect(player.slots[0].active);
    try player.stopAllSe();
    const buf = renderBlock(player, 1);
    try testing.expect(!player.slots[0].active);
    try testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-6);
}

test "SoundPlayer: render SR mismatch → all-zero + mismatch_detected" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const samples = [_]f32{1.0} ** 8;
    var sound = monoSound(&samples, 48000);
    try player.playSound(&sound, 1.0, 0.0);
    try testing.expect(!player.isMismatchDetected());

    var buf: [8]f32 = .{ 9, 9, 9, 9, 9, 9, 9, 9 };
    // Device supposedly delivered 44100
    player.render(&buf, 4, 2, 44100);
    for (buf) |s| try testing.expectEqual(@as(f32, 0.0), s);
    try testing.expect(player.isMismatchDetected());

    // On match, normal playback works; the flag is sticky (stays true until clear)
    player.clearMismatchDetected();
    try testing.expect(!player.isMismatchDetected());
    try player.playSound(&sound, 1.0, 0.0);
    player.render(&buf, 1, 2, 48000);
    try testing.expect(!player.isMismatchDetected());
    try testing.expect(buf[0] != 0.0 or buf[1] != 0.0);
}

test "SoundPlayer: render channels=0 → no panic, no-op + flag" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    var buf: [4]f32 = .{ 1, 2, 3, 4 };
    player.render(&buf, 4, 0, 48000);
    // Nowhere to write, so buf is unchanged
    try testing.expectEqual(@as(f32, 1), buf[0]);
    try testing.expectEqual(@as(f32, 2), buf[1]);
    try testing.expect(player.isMismatchDetected());
}

test "SoundPlayer: render channels=4 → zero-fill + flag" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();
    const samples = [_]f32{1.0} ** 4;
    var sound = monoSound(&samples, 48000);
    try player.playSound(&sound, 1.0, 0.0);

    var buf: [16]f32 = .{9} ** 16;
    player.render(&buf, 4, 4, 48000);
    for (buf) |s| try testing.expectEqual(@as(f32, 0.0), s);
    try testing.expect(player.isMismatchDetected());
}

test "SoundPlayer: NaN gain setters ignored / playSound refused" {
    const player = try Player4.create(testing.allocator, 48000);
    defer player.destroy();

    player.setMasterGain(0.5);
    player.setMasterGain(std.math.nan(f32));
    player.setMasterGain(std.math.inf(f32));
    // Confirm via render accumulation that it was not stored (master stays 0.5)
    const samples = [_]f32{1.0};
    var sound = monoSound(&samples, 48000);
    try player.playSound(&sound, 1.0, 0.0);
    const buf = renderBlock(player, 1);
    const c = dsp.equalPowerPan(0.0);
    try testing.expectApproxEqAbs(0.5 * c.l, buf[0], 1e-5);

    try testing.expectError(error.InvalidParameter, player.playSound(&sound, std.math.nan(f32), 0.0));
    try testing.expectError(error.InvalidParameter, player.playSound(&sound, 1.0, std.math.nan(f32)));
    try testing.expectError(error.InvalidParameter, player.playSound(&sound, std.math.inf(f32), 0.0));

    player.setSeGain(std.math.nan(f32));
    player.setBgmGain(std.math.inf(f32));
    // se/bgm stay at default 1.0 (NaN was not stored)
    try testing.expectEqual(@as(f32, 1.0), player.se_gain.load());
    try testing.expectEqual(@as(f32, 1.0), player.bgm_gain.load());
}
