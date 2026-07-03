//! apps/patch: マクロ（DrumMachine / BassMachine）テンプレ builder（TASK-40.7.1 / 40.7.2）。
//!
//! modular（DynGraph）に依存する純ロジック。platform/gui/canvas/group には依存しない
//! （group.Ledger への台帳登録は main.zig が publish 成功を確認してから行う。§3.2/§3.3）。
//!
//! ホットパス宣言: ここのループ（preflight のプール走査・add/connect/publish）は**イベント時のみ**
//! （マクロ追加ボタンのクリック時に 1 回）。RT（processBlock）・publish の RCU/triple-buffer 機構には
//! 一切触れない。

const std = @import("std");
const modular = @import("modular");

const DynGraph = modular.DynGraph;
pub const Handle = modular.dyn.Handle;

/// DrumMachine テンプレの kick/hat パターン（4 つ打ち / 裏拍 8 分。apps/modular/patch.zig の
/// KICK_ON/HAT_ON と同じ値。on_mask=0 だと gate が出ず無音になるため非空を明示）。
const KICK_MASK: u16 = 0x1111; // step 0,4,8,12
const HAT_MASK: u16 = 0x4444; // step 2,6,10,14

/// BassMachine テンプレのパターン（apps/modular/patch.zig の BASS_ON/BASS_ACCENT/BASS_SLIDE/BASS_DEG と同値。
/// on_mask/pitch_deg 非空で発音・音程を担保）。
const BASS_ON: u16 = 0x4949; // step 0,3,6,8,11,14
const BASS_ACCENT: u16 = 0x0101; // step 0,8
const BASS_SLIDE: u16 = 0x0808; // step 3,11
const BASS_DEG = [16]i8{ 0, 0, 0, 3, 0, 0, 2, 0, 0, 0, 0, 5, 0, 0, 2, 0 };

/// buildDrumMachine が add したモジュールの handle（テンプレの役割名で公開）。
pub const DrumMachineHandles = struct {
    cdiv: Handle,
    seq_k: Handle,
    seq_h: Handle,
    kick: Handle,
    hat: Handle,
    mix: Handle,
};

/// preflight: DrumMachine（cdiv/seqK/seqH/kick/hat/mix の 6 モジュール）を追加するのに必要な pool・handle の
/// 空きが足りるか確認する。dyn.zig の poolFreeCount/freeHandleCount は add() と同じ reclaim 条件を織り込んだ
/// 実確保可能数を返すので、ここでの判定は後続の add ループの成否と一致する。
fn preflightDrumMachine(g: *DynGraph) bool {
    if (g.freeHandleCount() < 6) return false;
    if (g.poolFreeCount(.clock_divider) < 1) return false;
    if (g.poolFreeCount(.step_seq) < 2) return false;
    if (g.poolFreeCount(.kick) < 1) return false;
    if (g.poolFreeCount(.hat) < 1) return false;
    if (g.poolFreeCount(.mixer) < 1) return false;
    return true;
}

/// preflight 済み前提の内部 builder。add→connect→1 publish。途中で失敗したら errdefer で
/// 既に add した分を removeModule で巻き戻す（publish 前なので既存 published view は不変＝RT 影響ゼロ）。
/// publish 自体が失敗した場合も同じ errdefer が効き、members を全 removeModule して台帳非登録のまま戻る
/// （RCU により旧 view が残るので RT は旧パッチのまま）。
///
/// 巻き戻した slot は次の publish+consume（grace）まで再利用不能＝一時的な pool/handle 消費が残る
/// （preflight が主対策で、この関数は defensive。公開 API は buildDrumMachine の preflight 込み経路のみで、
/// この関数はテストが preflight を迂回して rollback を直接検証するために file-private で残す）。
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

    try g.connect(cdiv, 0, seq_k, 0); // clock fan-out（出力は fan-out 可）
    try g.connect(cdiv, 0, seq_h, 0);
    try g.connect(seq_k, 0, kick, 0);
    try g.connect(seq_h, 0, hat, 0);
    try g.connect(kick, 0, mix, 0);
    try g.connect(hat, 0, mix, 1);

    try g.publish();

    return .{ .cdiv = cdiv, .seq_k = seq_k, .seq_h = seq_h, .kick = kick, .hat = hat, .mix = mix };
}

/// イベント時のみ。DrumMachine（cdiv/seqK/seqH/kick/hat/mix の 6 モジュール・固定配線）を追加し
/// 1 publish する。preflight で空きが足りなければ何も add せず error.PoolFull/TooManyModules を返す。
/// 呼び出し側（main.zig）は publish 成功を確認してから group.Ledger へ台帳登録する（§3.2）。
pub fn buildDrumMachine(g: *DynGraph) !DrumMachineHandles {
    if (!preflightDrumMachine(g)) return error.PoolFull;
    return buildMembersUnchecked(g);
}

// ============================================================================
// BassMachine（TASK-40.7.2・5 モジュール。全ポート実 spec 確認済み）:
//   seq=StepSeq(.bass) / vco=Vco / vcf=Vcf / env=EnvGen / vca=Vca
//   seq.out1(pitch cv)→vco.in0(cv)  vco.out0(audio)→vcf.in0(audio)
//   seq.out2(accent cv)→vcf.in1(cv) seq.out0(gate)→env.in0(gate)
//   vcf.out0(audio)→vca.in0(audio)  env.out0(cv)→vca.in1(cv)
//   expose: clock in = seq.in0(gate)（単一メンバー宛なので ClockDivider 不要）/ audio out = vca.out0(audio)
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

/// preflight 済み前提の内部 builder（DrumMachine と同型の errdefer rollback）。
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

/// イベント時のみ。BassMachine（5 モジュール・固定配線）を追加し 1 publish する。preflight で空きが
/// 足りなければ何も add せず error を返す。呼び出し側は publish 成功を確認してから台帳登録する。
pub fn buildBassMachine(g: *DynGraph) !BassMachineHandles {
    if (!preflightBassMachine(g)) return error.PoolFull;
    return buildBassMembersUnchecked(g);
}

// ============================================================================
// tests（display/audio 不要・test-macro）
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
    _ = try buildDrumMachine(g); // 無関係な追加（clock 未接続。1 publish 込み）
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

    // 300bpm/ppqn4 @48kHz → 2400 samples/tick。6000 samples で 2 tick 分の余裕を見る。
    var buf: [6000 * 2]f32 = undefined;
    g.processBlock(&buf, 6000, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}

test "macro: preflight rejects when a required pool is full (no partial add)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    // step_seq pool を cap まで埋める（cap は poolCap に追随＝ハードコードしない。40.7.2 で 4→8）。
    var i: usize = 0;
    while (i < modular.dyn.poolCap(.step_seq)) : (i += 1) _ = try g.add(.step_seq, .{});
    const before = g.activeCount();
    try testing.expectError(error.PoolFull, buildDrumMachine(g));
    try testing.expectEqual(before, g.activeCount()); // 何も追加されていない
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

    // mixer pool(cap=8) を使い切り、buildMembersUnchecked の最後の add（mixer）だけ失敗させる
    // （preflight は迂回して直接呼ぶ＝preflight が防ぐはずの状況を人為的に再現）。
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = try g.add(.mixer, .{});
    const active_before_attempt = g.activeCount();

    try testing.expectError(error.PoolFull, buildMembersUnchecked(g));

    // rollback: cdiv/seqK/seqH/kick/hat の 5 つが removeModule で戻り、activeCount が試行前に戻る。
    try testing.expectEqual(active_before_attempt, g.activeCount());
    // publish していないので published view は不変。
    const view_after = g.currentView();
    try testing.expectEqual(view_before.gen, view_after.gen);
    try testing.expectEqual(view_before.node_count, view_after.node_count);

    // 一時枯渇: 巻き戻した clock_divider の slot は grace 前なので retired のまま
    // （poolFreeCount が cap-1 を返す＝1 個分が一時的に使用不能）。
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
    g.processBlock(&buf, 64, 2); // consumed_gen を進めて grace 成立させる

    // grace 後は再度 buildDrumMachine が同じ 6 handle を再利用できる（findFreeHandle は最小 index から）。
    const h2 = try buildDrumMachine(g);
    try testing.expectEqual(h.cdiv, h2.cdiv);
    try testing.expectEqual(h.seq_k, h2.seq_k);
    try testing.expectEqual(h.seq_h, h2.seq_h);
    try testing.expectEqual(h.kick, h2.kick);
    try testing.expectEqual(h.hat, h2.hat);
    try testing.expectEqual(h.mix, h2.mix);
}

// --- BassMachine（TASK-40.7.2）---

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
    try g.connect(clock, 0, h.seq, 0); // clock → seq.gate（単一メンバー宛）
    try g.connect(h.vca, 0, out, 0);
    g.setOutput(out);
    try g.publish();

    var buf: [6000 * 2]f32 = undefined;
    g.processBlock(&buf, 6000, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0); // 発音（silent=0 相当）
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

    // env_gen pool(cap=12) を使い切り、builder の env add を失敗させる（preflight 迂回で直接呼ぶ）。
    var i: usize = 0;
    while (i < modular.dyn.poolCap(.env_gen)) : (i += 1) _ = try g.add(.env_gen, .{});
    const active_before_attempt = g.activeCount();

    try testing.expectError(error.PoolFull, buildBassMembersUnchecked(g));
    try testing.expectEqual(active_before_attempt, g.activeCount()); // seq/vco/vcf が巻き戻る
    const view_after = g.currentView();
    try testing.expectEqual(view_before.gen, view_after.gen); // publish していない
}

test "macro: DrumMachine×2 + BassMachine fit within step_seq cap (poolCap 4→8)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    _ = try buildDrumMachine(g); // step_seq ×2
    _ = try buildDrumMachine(g); // step_seq ×2（計 4）
    _ = try buildBassMachine(g); // step_seq ×1（計 5 <= cap 8）
    try testing.expect(g.poolFreeCount(.step_seq) >= 0);
    // step_seq が cap8 なので 5 個使っても余りがある。
    try testing.expectEqual(modular.dyn.poolCap(.step_seq) - 5, g.poolFreeCount(.step_seq));
}
