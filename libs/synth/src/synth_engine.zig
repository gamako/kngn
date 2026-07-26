//! Synth: bundles NoteQueue(GUI→Audio) + Patch(Mailbox) + VoicePool.
//!
//! producer (GUI thread): sendNoteOn/Off, panicAllNotesOff, publishPatch
//! consumer (RT thread): render(buf, frames, channels) — apply notes and synthesise/mix voices.
//! The patch is latched once at the block head (Mailbox.acquire; eliminates mid-block inconsistency).

const std = @import("std");
const dsp = @import("dsp");
const ring = @import("ring.zig");
const params = @import("params.zig");
const voice = @import("voice.zig");

pub const Patch = voice.Patch;

pub fn Synth(comptime max_voices: usize) type {
    return struct {
        const Self = @This();
        const Queue = ring.NoteQueue(256, 16); // 256 events; reserve 16 slots for note_off

        pool: voice.VoicePool(max_voices) = .{},
        queue: Queue = .{},
        patch_db: params.Mailbox(Patch),
        sample_rate: f32,
        panic_seen: u32 = 0,
        // Parameter smoothing (avoid clicks on abrupt changes): gain is a linear ramp inside the block; cutoff is one-pole smoothed.
        smoothed_gain: f32,
        smoothed_cutoff: f32,

        const cutoff_smooth: f32 = 0.3; // One-pole smoothing coefficient (0..1; larger follows faster)
        /// Chunk size for voice-major synthesis (fixed-length stack accumulator; 512B).
        const render_chunk: u32 = 128;

        pub fn init(sample_rate: f32, initial_patch: Patch) Self {
            return .{
                .patch_db = params.Mailbox(Patch).init(initial_patch),
                .sample_rate = sample_rate,
                .smoothed_gain = initial_patch.gain,
                .smoothed_cutoff = initial_patch.cutoff,
            };
        }

        // ---- producer (GUI / input thread) ----

        pub fn sendNoteOn(self: *Self, note: u8, velocity: f32) bool {
            return self.queue.sendNoteOn(note, velocity);
        }
        pub fn sendNoteOff(self: *Self, note: u8) bool {
            return self.queue.sendNoteOff(note);
        }
        pub fn panicAllNotesOff(self: *Self) void {
            self.queue.panicAllNotesOff();
        }
        pub fn publishPatch(self: *Self, patch: Patch) void {
            self.patch_db.publish(patch);
        }

        // ---- consumer (Audio RT thread) ----

        /// Apply note events → read the patch → synthesise voices → write interleaved output.
        /// Called on the RT thread. No malloc/lock/IO.
        pub fn render(self: *Self, buf: []f32, frames: u32, channels: u32) void {
            // 0. Latch the patch once at the block head (including note_ons drained in this block
            //    so the whole block uses one patch = no mid-block inconsistency)
            const patch = self.patch_db.acquire().*;

            // 1. Drain note events
            while (self.queue.pop()) |ev| {
                switch (ev) {
                    .note_on => |n| self.pool.noteOn(n.note, n.velocity, patch, self.sample_rate),
                    .note_off => |n| self.pool.noteOff(n.note),
                }
            }
            // 2. Panic (all notes off)
            if (self.queue.takePanic(&self.panic_seen)) self.pool.allNotesOff();

            // 3. One-pole-smooth cutoff and apply the filter at the block head.
            self.smoothed_cutoff += (patch.cutoff - self.smoothed_cutoff) * cutoff_smooth;
            var block_patch = patch;
            block_patch.cutoff = self.smoothed_cutoff;
            self.pool.prepareBlock(block_patch);

            // 4. Voice-major synthesis: per CHUNK, accumulate voices in order into a stack accumulator,
            //    apply the gain ramp (global frame index = same t as the former sample-major path), then
            //    write interleaved. RT path: acc is a fixed-length stack (512B); no heap allocation.
            const g0 = self.smoothed_gain;
            const g1 = patch.gain;
            const inv: f32 = if (frames > 0) 1.0 / @as(f32, @floatFromInt(frames)) else 0;
            var acc: [render_chunk]f32 = undefined;
            var done: u32 = 0;
            while (done < frames) {
                const n: u32 = @min(render_chunk, frames - done);
                @memset(acc[0..n], 0);
                self.pool.renderBlock(self.sample_rate, acc[0..n]);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const gi = done + i; // global frame index
                    const t: f32 = @as(f32, @floatFromInt(gi)) * inv;
                    const gain = g0 + (g1 - g0) * t;
                    const sample = acc[i] * gain;
                    var ch: u32 = 0;
                    while (ch < channels) : (ch += 1) {
                        buf[gi * channels + ch] = sample;
                    }
                }
                done += n;
            }
            self.smoothed_gain = g1;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "Synth.render: note_on produces non-silent output, note_off + release returns to silence" {
    var synth = Synth(8).init(48000, .{
        .attack = 0.0001,
        .decay = 0.0001,
        .sustain = 0.8,
        .release = 0.0001,
        .cutoff = 12000,
        .gain = 0.5,
    });

    var buf: [128]f32 = undefined; // 64 frames stereo

    // Before the note: silence
    synth.render(&buf, 64, 2);
    var energy: f32 = 0;
    for (buf) |s| energy += @abs(s);
    try testing.expectEqual(@as(f32, 0.0), energy);

    // note_on → sound appears
    try testing.expect(synth.sendNoteOn(69, 1.0)); // A4
    synth.render(&buf, 64, 2);
    energy = 0;
    for (buf) |s| energy += @abs(s);
    try testing.expect(energy > 0.0);

    // L/R identical (mono → interleaved duplicate)
    try testing.expectEqual(buf[0], buf[1]);

    // note_off → after release the voice is reclaimed and returns to silence
    try testing.expect(synth.sendNoteOff(69));
    var iter: u32 = 0;
    while (iter < 20) : (iter += 1) synth.render(&buf, 64, 2);
    try testing.expectEqual(@as(usize, 0), synth.pool.activeCount());
}

test "Synth.render: panic (all notes off) silences active voices" {
    var synth = Synth(8).init(48000, .{ .attack = 0.5, .release = 0.5, .gain = 0.5 });
    var buf: [64]f32 = undefined;
    _ = synth.sendNoteOn(60, 1.0);
    _ = synth.sendNoteOn(64, 1.0);
    _ = synth.sendNoteOn(67, 1.0);
    synth.render(&buf, 32, 2);
    try testing.expectEqual(@as(usize, 3), synth.pool.activeCount());

    // Panic → all voices release (reclaimed eventually even with long attack/release)
    synth.panicAllNotesOff();
    synth.render(&buf, 32, 2);
    for (synth.pool.voices) |v| {
        if (v.active) try testing.expectEqual(dsp.Envelope.Stage.release, v.env.stage);
    }
}

test "Synth: cutoff/gain are smoothed (no instant jump on patch change)" {
    var synth = Synth(4).init(48000, .{ .cutoff = 1000, .gain = 0.0, .sustain = 1.0, .attack = 0.0 });
    // Change the target sharply
    synth.publishPatch(.{ .cutoff = 5000, .gain = 1.0, .sustain = 1.0, .attack = 0.0 });
    var buf: [64]f32 = undefined;
    synth.render(&buf, 32, 2);
    // cutoff does not reach the target in one block under one-pole smoothing (between 1000 and 5000)
    try testing.expect(synth.smoothed_cutoff > 1000.0 and synth.smoothed_cutoff < 5000.0);
    // gain also reaches the target after one block (after the ramp)
    try testing.expectApproxEqAbs(@as(f32, 1.0), synth.smoothed_gain, 1e-6);
    // After a few blocks cutoff converges to the target
    var i: u32 = 0;
    while (i < 50) : (i += 1) synth.render(&buf, 32, 2);
    try testing.expectApproxEqAbs(@as(f32, 5000.0), synth.smoothed_cutoff, 1.0);
}

test "Synth: publishPatch changes waveform used by subsequent notes" {
    var synth = Synth(4).init(48000, .{ .waveform = .sine, .gain = 0.5 });
    synth.publishPatch(.{ .waveform = .square, .attack = 0.0, .sustain = 1.0, .gain = 0.5 });
    var buf: [32]f32 = undefined;
    _ = synth.sendNoteOn(69, 1.0);
    synth.render(&buf, 16, 2);
    // square + sustain1.0 so each sample sits near ±gain (larger than a sine's mid values)
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak > 0.0);
    // Confirm the applied waveform
    for (synth.pool.voices) |v| {
        if (v.active) try testing.expectEqual(dsp.Waveform.square, v.oscs[0].waveform);
    }
}

test "Synth.render: voice-major matches sample-major reference on every sample under IEEE ==" {
    // Prepare two engines with the same patch / note sequence; compare the new render() (voice-major) against
    // a reference (pool.renderSample every sample + the same gain ramp).
    // Addition order (voice-index order) matches, so they agree under IEEE numeric equality (==; -0.0 and +0.0 treated equal).
    const patch = Patch{
        .attack = 0.001,
        .sustain = 0.8,
        .release = 0.05,
        .cutoff = 2000,
        .resonance = 1.2,
        .gain = 0.5,
        .vibrato_depth = 0.3, // Also exercise the control-tick path
        .filter_env_amount = 2.0,
        .filter_sustain = 0.5,
        .unison = 3,
        .detune = 12.0,
    };
    var a = Synth(8).init(48000, patch);
    var b = Synth(8).init(48000, patch);
    for ([_]u8{ 60, 64, 67 }) |n| {
        _ = a.sendNoteOn(n, 0.9);
        _ = b.sendNoteOn(n, 0.9);
    }

    var buf_a: [2 * 200]f32 = undefined;
    var buf_b: [2 * 200]f32 = undefined;
    var block: u32 = 0;
    while (block < 6) : (block += 1) {
        // Multiple blocks + odd frame counts (chunk straddles / tails) + note off / reclaim straddles
        const frames: u32 = if (block % 2 == 0) 200 else 137;
        a.render(buf_a[0 .. frames * 2], frames, 2);
        renderSampleMajorRef(&b, buf_b[0 .. frames * 2], frames, 2);
        for (buf_a[0 .. frames * 2], buf_b[0 .. frames * 2]) |sa, sb| {
            try testing.expectEqual(sa, sb);
        }
        if (block == 2) {
            _ = a.sendNoteOff(64);
            _ = b.sendNoteOff(64);
        }
    }
}

/// Reference implementing the former sample-major procedure (same drain/patch/gain handling as render).
fn renderSampleMajorRef(self: *Synth(8), buf: []f32, frames: u32, channels: u32) void {
    const patch = self.patch_db.acquire().*; // Same block-head latch as render
    while (self.queue.pop()) |ev| {
        switch (ev) {
            .note_on => |n| self.pool.noteOn(n.note, n.velocity, patch, self.sample_rate),
            .note_off => |n| self.pool.noteOff(n.note),
        }
    }
    if (self.queue.takePanic(&self.panic_seen)) self.pool.allNotesOff();
    self.smoothed_cutoff += (patch.cutoff - self.smoothed_cutoff) * Synth(8).cutoff_smooth;
    var block_patch = patch;
    block_patch.cutoff = self.smoothed_cutoff;
    self.pool.prepareBlock(block_patch);
    const g0 = self.smoothed_gain;
    const g1 = patch.gain;
    const inv: f32 = if (frames > 0) 1.0 / @as(f32, @floatFromInt(frames)) else 0;
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) * inv;
        const gain = g0 + (g1 - g0) * t;
        const sample = self.pool.renderSample(self.sample_rate) * gain;
        var ch: u32 = 0;
        while (ch < channels) : (ch += 1) {
            buf[i * channels + ch] = sample;
        }
    }
    self.smoothed_gain = g1;
}

test "Voice: transcendentals are control-rate (ctrl_ticks upper bound + filter_recalcs stop after sustain)" {
    const voice_mod = @import("voice.zig");
    var synth = Synth(4).init(48000, .{
        .attack = 0.001,
        .decay = 0.01,
        .sustain = 0.8,
        .vibrato_depth = 0.3,
        .filter_env_amount = 2.0,
        .filter_attack = 0.005,
        .filter_decay = 0.02,
        .filter_sustain = 0.5,
        .gain = 0.5,
    });
    _ = synth.sendNoteOn(60, 1.0);
    var buf: [256 * 2]f32 = undefined;

    // Render N samples; tick count must be <= ceil(N/16) + block count (prepareBlock resets)
    const blocks: u32 = 20;
    const frames: u32 = 256;
    var bi: u32 = 0;
    while (bi < blocks) : (bi += 1) synth.render(&buf, frames, 2);
    const total: u32 = blocks * frames;
    const v = &synth.pool.voices[0];
    try testing.expect(v.active);
    const max_ticks = (total + voice_mod.CTRL_PERIOD - 1) / voice_mod.CTRL_PERIOD + blocks;
    try testing.expect(v.ctrl_ticks <= max_ticks);
    try testing.expect(v.ctrl_ticks > 0);

    // After filter env reaches sustain (constant value), dirty-gate stops further setParams
    const recalcs_settled = v.filter_recalcs;
    var extra: u32 = 0;
    while (extra < 10) : (extra += 1) synth.render(&buf, frames, 2);
    try testing.expectEqual(recalcs_settled, v.filter_recalcs);
    // Sound is present (decimation has not silenced it)
    var energy: f32 = 0;
    for (buf) |smp| energy += @abs(smp);
    try testing.expect(energy > 0.0);
}
