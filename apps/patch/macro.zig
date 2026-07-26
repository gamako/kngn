//! apps/patch: template builder for macros (DrumMachine / BassMachine).
//!
//! Pure logic depending on modular (DynGraph). Does not depend on platform/gui/canvas/group
//! (registering the ledger entry in group.Ledger is done by main.zig only after confirming publish succeeded).
//!
//! Hot-path declaration: the loops here (preflight pool scan, add/connect/publish) run **only on events**
//! (once per click of the add-macro button). Never touches RT (processBlock) or publish's RCU/triple-buffer
//! mechanism.

const std = @import("std");
const modular = @import("modular");

const DynGraph = modular.DynGraph;
pub const Handle = modular.dyn.Handle;

/// libs/modular is the single source for the DrumMachine / BassMachine template initial values.
const KICK_MASK = modular.grid_presets.KICK_ON;
const HAT_MASK = modular.grid_presets.HAT_ON;
const BASS_ON = modular.grid_presets.BASS_ON;
const BASS_ACCENT = modular.grid_presets.BASS_ACCENT;
const BASS_SLIDE = modular.grid_presets.BASS_SLIDE;
const BASS_DEG = modular.grid_presets.BASS_DEG;

/// Handles of the modules added by buildDrumMachine (exposed under the template's role names).
pub const DrumMachineHandles = struct {
    cdiv: Handle,
    seq_k: Handle,
    seq_h: Handle,
    kick: Handle,
    hat: Handle,
    mix: Handle,
};

/// preflight: checks whether there's enough pool/handle headroom to add DrumMachine (6 modules: cdiv/seqK/seqH/kick/hat/mix)
/// availability. dyn.zig's poolFreeCount/freeHandleCount factor in the same reclaim conditions as add(), so
/// they return the actual allocatable count, and the judgment here matches the outcome of the subsequent add loop.
fn preflightDrumMachine(g: *DynGraph) bool {
    if (g.freeHandleCount() < 6) return false;
    if (g.poolFreeCount(.clock_divider) < 1) return false;
    if (g.poolFreeCount(.step_seq) < 2) return false;
    if (g.poolFreeCount(.kick) < 1) return false;
    if (g.poolFreeCount(.hat) < 1) return false;
    if (g.poolFreeCount(.mixer) < 1) return false;
    return true;
}

/// Internal builder assuming preflight has already run. add→connect→1 publish. On failure midway, errdefer
/// rolls back everything already added via removeModule (since this is before publish, the existing published view is unchanged — zero RT impact).
/// If publish itself fails, the same errdefer applies, removeModule-ing all members and returning without registering the ledger entry
/// (RCU keeps the old view intact, so RT stays on the old patch).
///
/// Rolled-back slots are unusable until the next publish+consume (grace) — temporary pool/handle consumption remains
/// (preflight is the primary safeguard; this function is defensive. The public API is only buildDrumMachine's preflight-inclusive path;
/// this function stays file-private so tests can bypass preflight and verify rollback directly).
fn buildMembersUnchecked(g: *DynGraph) !DrumMachineHandles {
    var added: [6]Handle = undefined;
    var n_added: usize = 0;
    errdefer {
        var i = n_added;
        while (i > 0) {
            i -= 1;
            g.removeModule(added[i]);
        }
    }

    const cdiv = try g.add(.clock_divider, .{ .div = 1 });
    added[n_added] = cdiv;
    n_added += 1;
    const seq_k = try g.add(.step_seq, .{ .kind = .drum, .on_mask = KICK_MASK });
    added[n_added] = seq_k;
    n_added += 1;
    const seq_h = try g.add(.step_seq, .{ .kind = .drum, .on_mask = HAT_MASK });
    added[n_added] = seq_h;
    n_added += 1;
    const kick = try g.add(.kick, .{});
    added[n_added] = kick;
    n_added += 1;
    const hat = try g.add(.hat, .{});
    added[n_added] = hat;
    n_added += 1;
    const mix = try g.add(.mixer, .{});
    added[n_added] = mix;
    n_added += 1;

    try g.connect(cdiv, 0, seq_k, 0); // clock fan-out (the output can fan out)
    try g.connect(cdiv, 0, seq_h, 0);
    try g.connect(seq_k, 0, kick, 0);
    try g.connect(seq_h, 0, hat, 0);
    try g.connect(kick, 0, mix, 0);
    try g.connect(hat, 0, mix, 1);

    try g.publish();

    return .{ .cdiv = cdiv, .seq_k = seq_k, .seq_h = seq_h, .kick = kick, .hat = hat, .mix = mix };
}

/// Event-time only. Adds DrumMachine (6 modules: cdiv/seqK/seqH/kick/hat/mix, fixed wiring) and
/// performs 1 publish. If preflight finds insufficient headroom, adds nothing and returns error.PoolFull/TooManyModules.
/// The caller (main.zig) registers the ledger entry in group.Ledger only after confirming publish succeeded.
pub fn buildDrumMachine(g: *DynGraph) !DrumMachineHandles {
    if (!preflightDrumMachine(g)) return error.PoolFull;
    return buildMembersUnchecked(g);
}

// ============================================================================
// BassMachine (5 modules; all ports verified against the actual spec):
//   seq=StepSeq(.bass) / vco=Vco / vcf=Vcf / env=EnvGen / vca=Vca
//   seq.out1(pitch cv)→vco.in0(cv)  vco.out0(audio)→vcf.in0(audio)
//   seq.out2(accent cv)→vcf.in1(cv) seq.out0(gate)→env.in0(gate)
//   vcf.out0(audio)→vca.in0(audio)  env.out0(cv)→vca.in1(cv)
//   expose: clock in = seq.in0(gate) (no ClockDivider needed since it targets a single member) / audio out = vca.out0(audio)
// ============================================================================

pub const BassMachineHandles = struct {
    seq: Handle,
    vco: Handle,
    vcf: Handle,
    env: Handle,
    vca: Handle,
};

fn preflightBassMachine(g: *DynGraph) bool {
    if (g.freeHandleCount() < 5) return false;
    if (g.poolFreeCount(.step_seq) < 1) return false;
    if (g.poolFreeCount(.vco) < 1) return false;
    if (g.poolFreeCount(.vcf) < 1) return false;
    if (g.poolFreeCount(.env_gen) < 1) return false;
    if (g.poolFreeCount(.vca) < 1) return false;
    return true;
}

/// Internal builder assuming preflight has already run (same errdefer rollback shape as DrumMachine).
fn buildBassMembersUnchecked(g: *DynGraph) !BassMachineHandles {
    var added: [5]Handle = undefined;
    var n_added: usize = 0;
    errdefer {
        var i = n_added;
        while (i > 0) {
            i -= 1;
            g.removeModule(added[i]);
        }
    }

    const seq = try g.add(.step_seq, .{ .kind = .bass, .on_mask = BASS_ON, .accent_mask = BASS_ACCENT, .slide_mask = BASS_SLIDE, .pitch_deg = BASS_DEG });
    added[n_added] = seq;
    n_added += 1;
    const vco = try g.add(.vco, .{});
    added[n_added] = vco;
    n_added += 1;
    const vcf = try g.add(.vcf, .{ .cutoff = 800, .resonance = 3.0, .mode = .lowpass });
    added[n_added] = vcf;
    n_added += 1;
    const env = try g.add(.env_gen, .{});
    added[n_added] = env;
    n_added += 1;
    const vca = try g.add(.vca, .{ .gain = 0.9 });
    added[n_added] = vca;
    n_added += 1;

    try g.connect(seq, 1, vco, 0); // pitch cv → vco
    try g.connect(vco, 0, vcf, 0); // audio → vcf
    try g.connect(seq, 2, vcf, 1); // accent cv → vcf cutoff
    try g.connect(seq, 0, env, 0); // gate → env
    try g.connect(vcf, 0, vca, 0); // audio → vca
    try g.connect(env, 0, vca, 1); // env cv → vca gain

    try g.publish();

    return .{ .seq = seq, .vco = vco, .vcf = vcf, .env = env, .vca = vca };
}

/// Event-time only. Adds BassMachine (5 modules, fixed wiring) and performs 1 publish. If preflight finds
/// insufficient headroom, adds nothing and returns an error. The caller registers the ledger entry only after confirming publish succeeded.
pub fn buildBassMachine(g: *DynGraph) !BassMachineHandles {
    if (!preflightBassMachine(g)) return error.PoolFull;
    return buildBassMembersUnchecked(g);
}

// ============================================================================
// tests (no display/audio needed; test-macro)
// ============================================================================
const testing = std.testing;

fn rmsEven(buf: []const f32, channels: u32) f32 {
    var acc: f64 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += channels) {
        acc += @as(f64, buf[i]) * @as(f64, buf[i]);
        n += 1;
    }
    return @floatCast(@sqrt(acc / @as(f64, @floatFromInt(n))));
}

test "macro: buildDrumMachine is deterministic (same members/edges across 2 builds)" {
    const build = struct {
        fn go(alloc: std.mem.Allocator) !struct { view: modular.GraphView, h: DrumMachineHandles } {
            const g = try DynGraph.create(alloc, 48000);
            defer g.destroy();
            const h = try buildDrumMachine(g);
            return .{ .view = g.currentView(), .h = h };
        }
    };
    const a = try build.go(testing.allocator);
    const b = try build.go(testing.allocator);
    try testing.expectEqual(a.h.cdiv, b.h.cdiv);
    try testing.expectEqual(a.h.seq_k, b.h.seq_k);
    try testing.expectEqual(a.h.seq_h, b.h.seq_h);
    try testing.expectEqual(a.h.kick, b.h.kick);
    try testing.expectEqual(a.h.hat, b.h.hat);
    try testing.expectEqual(a.h.mix, b.h.mix);
    try testing.expectEqual(a.view.node_count, b.view.node_count);
    try testing.expectEqualSlices(u16, a.view.order[0..a.view.node_count], b.view.order[0..b.view.node_count]);
}

test "macro: adding DrumMachine mid-render does not disturb existing VCO->Output stream" {
    var ref = try DynGraph.create(testing.allocator, 48000);
    defer ref.destroy();
    {
        const v = try ref.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
        const o = try ref.add(.output, .{ .soft_clip = false, .pan = 0.0 });
        try ref.connect(v, 0, o, 0);
        ref.setOutput(o);
        try ref.publish();
    }
    var ref_b1: [128 * 2]f32 = undefined;
    var ref_b2: [128 * 2]f32 = undefined;
    ref.processBlock(&ref_b1, 128, 2);
    ref.processBlock(&ref_b2, 128, 2);

    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const o = try g.add(.output, .{ .soft_clip = false, .pan = 0.0 });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    var g_b1: [128 * 2]f32 = undefined;
    var g_b2: [128 * 2]f32 = undefined;
    g.processBlock(&g_b1, 128, 2);
    _ = try buildDrumMachine(g); // Unrelated addition (clock left unconnected; includes 1 publish)
    g.processBlock(&g_b2, 128, 2);

    try testing.expectEqualSlices(f32, &ref_b1, &g_b1);
    try testing.expectEqualSlices(f32, &ref_b2, &g_b2);
}

test "macro: DrumMachine produces sound once clocked (on_mask non-empty regression guard)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const h = try buildDrumMachine(g);
    const clock = try g.add(.clock, .{ .bpm = 300, .ppqn = 4 });
    const out = try g.add(.output, .{ .soft_clip = true, .pan = 0.0 });
    try g.connect(clock, 0, h.cdiv, 0);
    try g.connect(h.mix, 0, out, 0);
    g.setOutput(out);
    try g.publish();

    // 300bpm/ppqn4 @48kHz → 2400 samples/tick. 6000 samples allows margin for 2 ticks.
    var buf: [6000 * 2]f32 = undefined;
    g.processBlock(&buf, 6000, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}

test "macro: preflight rejects when a required pool is full (no partial add)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    // Fills the step_seq pool up to cap (cap tracks poolCap; not hardcoded).
    var i: usize = 0;
    while (i < modular.dyn.poolCap(.step_seq)) : (i += 1) _ = try g.add(.step_seq, .{});
    const before = g.activeCount();
    try testing.expectError(error.PoolFull, buildDrumMachine(g));
    try testing.expectEqual(before, g.activeCount()); // Nothing added
}

test "macro: post-preflight add failure rolls back members; published view + pool count stay consistent" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{});
    const o = try g.add(.output, .{});
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    const view_before = g.currentView();

    // Exhausts the mixer pool (cap=8) so only the last add (mixer) in buildMembersUnchecked fails
    // (bypasses preflight and calls directly — artificially reproducing the situation preflight is meant to prevent).
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = try g.add(.mixer, .{});
    const active_before_attempt = g.activeCount();

    try testing.expectError(error.PoolFull, buildMembersUnchecked(g));

    // rollback: the 5 modules cdiv/seqK/seqH/kick/hat are reverted via removeModule, and activeCount returns to its pre-attempt value.
    try testing.expectEqual(active_before_attempt, g.activeCount());
    // Since publish never ran, the published view is unchanged.
    const view_after = g.currentView();
    try testing.expectEqual(view_before.gen, view_after.gen);
    try testing.expectEqual(view_before.node_count, view_after.node_count);

    // Temporary depletion: the rolled-back clock_divider slot stays retired since it's before grace
    // (poolFreeCount returns cap-1 — one slot is temporarily unusable).
    try testing.expectEqual(modular.dyn.poolCap(.clock_divider) - 1, g.poolFreeCount(.clock_divider));
}

test "macro: group deletion (remove all members + publish) allows handle reuse after grace" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const h = try buildDrumMachine(g);
    g.removeModule(h.cdiv);
    g.removeModule(h.seq_k);
    g.removeModule(h.seq_h);
    g.removeModule(h.kick);
    g.removeModule(h.hat);
    g.removeModule(h.mix);
    try g.publish();
    var buf: [64 * 2]f32 = undefined;
    g.processBlock(&buf, 64, 2); // Advances consumed_gen so grace takes effect

    // After grace, buildDrumMachine can reuse the same 6 handles again (findFreeHandle starts from the smallest index).
    const h2 = try buildDrumMachine(g);
    try testing.expectEqual(h.cdiv, h2.cdiv);
    try testing.expectEqual(h.seq_k, h2.seq_k);
    try testing.expectEqual(h.seq_h, h2.seq_h);
    try testing.expectEqual(h.kick, h2.kick);
    try testing.expectEqual(h.hat, h2.hat);
    try testing.expectEqual(h.mix, h2.mix);
}

// --- BassMachine ---

test "macro: buildBassMachine is deterministic (same members/edges across 2 builds)" {
    const build = struct {
        fn go(alloc: std.mem.Allocator) !struct { view: modular.GraphView, h: BassMachineHandles } {
            const g = try DynGraph.create(alloc, 48000);
            defer g.destroy();
            const h = try buildBassMachine(g);
            return .{ .view = g.currentView(), .h = h };
        }
    };
    const a = try build.go(testing.allocator);
    const b = try build.go(testing.allocator);
    try testing.expectEqual(a.h.seq, b.h.seq);
    try testing.expectEqual(a.h.vco, b.h.vco);
    try testing.expectEqual(a.h.vcf, b.h.vcf);
    try testing.expectEqual(a.h.env, b.h.env);
    try testing.expectEqual(a.h.vca, b.h.vca);
    try testing.expectEqual(a.view.node_count, b.view.node_count);
    try testing.expectEqualSlices(u16, a.view.order[0..a.view.node_count], b.view.order[0..b.view.node_count]);
}

test "macro: BassMachine produces sound + finite pitch/accent CV once clocked" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const h = try buildBassMachine(g);
    const clock = try g.add(.clock, .{ .bpm = 300, .ppqn = 4 });
    const out = try g.add(.output, .{ .soft_clip = true, .pan = 0.0 });
    try g.connect(clock, 0, h.seq, 0); // clock → seq.gate (targets a single member)
    try g.connect(h.vca, 0, out, 0);
    g.setOutput(out);
    try g.publish();

    var buf: [6000 * 2]f32 = undefined;
    g.processBlock(&buf, 6000, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0); // Sound-producing (equivalent to silent=0)
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}

test "macro: BassMachine preflight rejects when vco pool is full (no partial add)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    var i: usize = 0;
    while (i < modular.dyn.poolCap(.vco)) : (i += 1) _ = try g.add(.vco, .{});
    const before = g.activeCount();
    try testing.expectError(error.PoolFull, buildBassMachine(g));
    try testing.expectEqual(before, g.activeCount());
}

test "macro: BassMachine post-preflight add failure rolls back; published view unchanged" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{});
    const o = try g.add(.output, .{});
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    const view_before = g.currentView();

    // Exhausts the env_gen pool (cap=12) so the builder's env add fails (bypasses preflight and calls directly).
    var i: usize = 0;
    while (i < modular.dyn.poolCap(.env_gen)) : (i += 1) _ = try g.add(.env_gen, .{});
    const active_before_attempt = g.activeCount();

    try testing.expectError(error.PoolFull, buildBassMembersUnchecked(g));
    try testing.expectEqual(active_before_attempt, g.activeCount()); // seq/vco/vcf get rolled back
    const view_after = g.currentView();
    try testing.expectEqual(view_before.gen, view_after.gen); // Has not published
}

test "macro: DrumMachine×2 + BassMachine fit within step_seq cap (poolCap 4→8)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    _ = try buildDrumMachine(g); // step_seq ×2
    _ = try buildDrumMachine(g); // step_seq ×2 (4 total)
    _ = try buildBassMachine(g); // step_seq ×1 (5 total <= cap 8)
    try testing.expect(g.poolFreeCount(.step_seq) >= 0);
    // Since step_seq has cap 8, there's headroom left even after using 5.
    try testing.expectEqual(modular.dyn.poolCap(.step_seq) - 5, g.poolFreeCount(.step_seq));
}

test "wire kind step_seq / step_seq_bass: nOut is drum=1 / bass=3" {
    // main.addNodeByKindName alias contract: step_seq=.{} (drum), step_seq_bass=bass init.
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const drum = try g.add(.step_seq, .{});
    const bass = try g.add(.step_seq, .{
        .kind = .bass,
        .on_mask = 0,
        .accent_mask = 0,
        .slide_mask = 0,
        .scale = .minor_pentatonic,
        .octaves = 2,
    });
    try testing.expectEqual(@as(u8, 1), g.nOut(drum));
    try testing.expectEqual(@as(u8, 3), g.nOut(bass));
    try testing.expect(g.ptrOfConst(.step_seq, drum).kind == .drum);
    try testing.expect(g.ptrOfConst(.step_seq, bass).kind == .bass);
}
