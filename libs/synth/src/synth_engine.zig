//! Synth: NoteQueue(GUI→Audio) + Patch(double-buffer) + VoicePool を束ねる本体。
//!
//! producer(GUIスレッド): sendNoteOn/Off, panicAllNotesOff, publishPatch
//! consumer(RTスレッド): render(buf, frames, channels) — note を反映しボイスを合成・ミックス。

const std = @import("std");
const dsp = @import("dsp");
const ring = @import("ring.zig");
const params = @import("params.zig");
const voice = @import("voice.zig");

pub const Patch = voice.Patch;

pub fn Synth(comptime max_voices: usize) type {
    return struct {
        const Self = @This();
        const Queue = ring.NoteQueue(256, 16); // 256 イベント、note_off に 16 枠予約

        pool: voice.VoicePool(max_voices) = .{},
        queue: Queue = .{},
        patch_db: params.DoubleBuffer(Patch),
        sample_rate: f32,
        panic_seen: u32 = 0,
        // パラメータスムージング（急変クリック回避）: gain はブロック内線形ランプ、cutoff は一次平滑。
        smoothed_gain: f32,
        smoothed_cutoff: f32,

        const cutoff_smooth: f32 = 0.3; // 一次平滑係数（0..1、大きいほど速く追従）

        pub fn init(sample_rate: f32, initial_patch: Patch) Self {
            return .{
                .patch_db = params.DoubleBuffer(Patch).init(initial_patch),
                .sample_rate = sample_rate,
                .smoothed_gain = initial_patch.gain,
                .smoothed_cutoff = initial_patch.cutoff,
            };
        }

        // ---- producer (GUI / 入力スレッド) ----

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

        // ---- consumer (Audio RT スレッド) ----

        /// note イベント反映 → patch 読み出し → ボイス合成 → interleaved 出力へ書き込み。
        /// RT スレッドで呼ばれる。malloc/lock/IO しない。
        pub fn render(self: *Self, buf: []f32, frames: u32, channels: u32) void {
            // 1. note イベントを drain
            while (self.queue.pop()) |ev| {
                switch (ev) {
                    .note_on => |n| self.pool.noteOn(n.note, n.velocity, self.currentPatch(), self.sample_rate),
                    .note_off => |n| self.pool.noteOff(n.note),
                }
            }
            // 2. パニック（全ノートオフ）
            if (self.queue.takePanic(&self.panic_seen)) self.pool.allNotesOff();

            // 3. patch を読み（整合的なスナップショット）。cutoff は一次平滑してブロック先頭で filter 反映。
            const patch = self.currentPatch();
            self.smoothed_cutoff += (patch.cutoff - self.smoothed_cutoff) * cutoff_smooth;
            var block_patch = patch;
            block_patch.cutoff = self.smoothed_cutoff;
            self.pool.prepareBlock(block_patch);

            // 4. フレームごとに合成して interleaved 書き込み。gain はブロック内で線形ランプ（zipper 回避）。
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

        fn currentPatch(self: *Self) Patch {
            return self.patch_db.current();
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

    // ノート前: 無音
    synth.render(&buf, 64, 2);
    var energy: f32 = 0;
    for (buf) |s| energy += @abs(s);
    try testing.expectEqual(@as(f32, 0.0), energy);

    // note_on → 音が出る
    try testing.expect(synth.sendNoteOn(69, 1.0)); // A4
    synth.render(&buf, 64, 2);
    energy = 0;
    for (buf) |s| energy += @abs(s);
    try testing.expect(energy > 0.0);

    // L/R が同じ（mono → interleaved 複製）
    try testing.expectEqual(buf[0], buf[1]);

    // note_off → release 後はボイス回収され無音へ
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

    // パニック → 全ボイス release（attack/release が長くてもいずれ回収）
    synth.panicAllNotesOff();
    synth.render(&buf, 32, 2);
    for (synth.pool.voices) |v| {
        if (v.active) try testing.expectEqual(dsp.Envelope.Stage.release, v.env.stage);
    }
}

test "Synth: cutoff/gain are smoothed (no instant jump on patch change)" {
    var synth = Synth(4).init(48000, .{ .cutoff = 1000, .gain = 0.0, .sustain = 1.0, .attack = 0.0 });
    // 目標を大きく変える
    synth.publishPatch(.{ .cutoff = 5000, .gain = 1.0, .sustain = 1.0, .attack = 0.0 });
    var buf: [64]f32 = undefined;
    synth.render(&buf, 32, 2);
    // cutoff は一次平滑で 1 ブロックでは目標へ到達しない（1000 と 5000 の中間）
    try testing.expect(synth.smoothed_cutoff > 1000.0 and synth.smoothed_cutoff < 5000.0);
    // gain も 1 ブロック後に目標へ（ランプ後）
    try testing.expectApproxEqAbs(@as(f32, 1.0), synth.smoothed_gain, 1e-6);
    // 数ブロックで cutoff は目標へ収束
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
    // square + sustain1.0 なので各サンプルは概ね ±gain 付近（正弦の中間値より大きい）
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    try testing.expect(peak > 0.0);
    // 適用された waveform を確認
    for (synth.pool.voices) |v| {
        if (v.active) try testing.expectEqual(dsp.Waveform.square, v.oscs[0].waveform);
    }
}
