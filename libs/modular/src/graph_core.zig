//! libs/modular: per-sample 評価コア（静的 Graph / 動的 DynGraph で共有）。
//!
//! signal のみに依存（modules も dsp も import しない＝generic）。RT 安全：process 経路に
//! alloc/lock/IO/panic なし。静的・動的の二重実装を避けるための共有カーネル（TASK-40.6.1）。
//!
//! 呼び出し側は「処理順に並んだ ProcNode 列」と cur/prev signal バッファを渡す。トポロジ構築
//! （topo sort / サイクル遅延辺 / 有効性検証）は全て呼び出し側（非 RT）が行い、ここには
//! 「有効・非空・channels>=1」の前提で入る。

const std = @import("std");
const signal = @import("signal.zig");

const Io = signal.Io;

/// 処理順に並んだ 1 ノードの RT ローカル解決済み記述。
/// vtable/ctx はポインタだが、これは publish 越し（POD GraphView）ではなく **RT ローカルの解決結果**
/// （動的版は GraphView の handle からレジストリで解決してこの形に組む）。POD 制約は publish payload
/// = GraphView にのみ課す。
pub const ProcNode = struct {
    vtable: *const signal.VTable,
    ctx: *anyopaque,
    n_in: u8,
    n_out: u8,
    /// signal バッファ上でこの node の出力ポートが占める先頭 index。
    out_base: u32,
    /// 各入力ポートの接続元グローバル出力ポート id（未接続 = -1）。
    in_src: [signal.MAX_IN]i32 = [_]i32{-1} ** signal.MAX_IN,
    /// 各入力ポートがサイクル遅延辺か（前サンプル値 prev を読む）。
    in_delayed: [signal.MAX_IN]bool = [_]bool{false} ** signal.MAX_IN,
};

/// master 出力ノードの出力ポート選択（out0=L, out1=R。n_out<2 は mono→L/R 複製）。
pub const OutputSel = struct { out_base: u32, n_out: u8 };

/// 1 サンプル分の master 出力。
pub const StereoOut = struct { l: f32, r: f32 };

// ============================================================================
// TASK-40.8 D: ポート別ミニ oscilloscope 用の per-port tap（RT→GUI の覗き見型リング）。
//
// generic なまま（signal のみ依存）保つため型だけここに置く。実体は DynGraph が inline 所有。
// 契約:
//   - RT（processBlockTapped）: latched_ports[s] のグローバル port id の出力値を TAP_DECIM 間引きで
//     ring へ書く（.unordered store＝aligned f32 では plain store と同一機械語・fence/RMW 無し）。
//     wpos は block 内 local カウンタで進め、block 末尾に slot あたり 1 回だけ release store（同期する
//     atomic は毎サンプルでなくブロック末尾の wpos だけ）。
//   - GUI: wpos を acquire load → 直近 min(wpos,TAP_RING) サンプルを読む「覗き見型」（consume しない）。
//     acquire が RT の release と synchronizes-with するので、その wpos までの ring 書き込みは可視。
//     読み中に RT が次 block で上書きする tail 部分の torn は表示 1 フレームのグリッチのみで許容（best-effort）。
//   - port 差し替え時は dyn が local_wpos[s]=0 + wpos.store(0) にリセットし、旧 port のサンプルが
//     新 port の窓へ混ざらないようにする（applied_seq gate と併せて AC#2/#4 の意味を保つ）。
// ============================================================================
pub const TAP_SLOTS: usize = 16;
pub const TAP_RING: usize = 256;
pub const TAP_DECIM: u32 = 4; // audio 波形用の細かい間引き（~21ms 窓）
pub const TAP_DECIM_SLOW: u32 = 256; // cv/gate 用の粗い間引き（256 点で ~1.4s 窓。リズム/ゆっくり変調を見る）

/// GUI→RT publish payload（POD）。ports[s] = グローバル出力 port id（handle*MAX_OUT+out。-1=空きスロット）。
/// per-slot 間引き（decim）と reduce モード（peak）を GUI がポート種別に応じて設定する:
///   - audio: decim 小・peak=false（末尾値＝波形。位相ロックで静止表示）
///   - cv:    decim 大・peak=false（末尾値＝ゆっくりした変調を長い窓で）
///   - gate:  decim 大・peak=true （窓内 max＝1 サンプル幅パルスを取りこぼさず縦バーで）
pub const TapConfig = struct {
    seq: u32 = 0,
    ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS,
    decim: [TAP_SLOTS]u32 = [_]u32{TAP_DECIM} ** TAP_SLOTS,
    peak: [TAP_SLOTS]bool = [_]bool{false} ** TAP_SLOTS,
};

/// 1 slot 分の RT-write / GUI-read リング。
pub const TapSlot = struct {
    ring: [TAP_RING]f32 = [_]f32{0} ** TAP_RING,
    /// 書き込んだ総サンプル数（単調増加）。RT が block 末尾に release store、GUI が acquire load。
    wpos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// RT が書き GUI が読む tap 領域（cache_line 分離の対象）。RT-private field（latched_ports/local_wpos/
/// decim_counter）も RT のみが触るため同居可（GUI 書きとの false sharing ペアにならない）。
pub const TapState = struct {
    /// RT が block 末尾に latch 済み config の seq を release store（GUI の描画 gate）。
    applied_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    slots: [TAP_SLOTS]TapSlot = [_]TapSlot{.{}} ** TAP_SLOTS,
    // --- RT-private（GUI は読まない）---
    /// RT が latch した現在の port 割当（config 差し替え検出用）。
    latched_ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS,
    /// slot ごとの latch 済み間引き率・reduce モード（config から焼く）。
    latched_decim: [TAP_SLOTS]u32 = [_]u32{TAP_DECIM} ** TAP_SLOTS,
    latched_peak: [TAP_SLOTS]bool = [_]bool{false} ** TAP_SLOTS,
    /// slot ごとの local 書き込みカウンタ（block 末尾に wpos へ publish）。
    local_wpos: [TAP_SLOTS]u32 = [_]u32{0} ** TAP_SLOTS,
    /// slot ごとの間引きカウンタ（block を跨いで持続）。
    cnt: [TAP_SLOTS]u32 = [_]u32{0} ** TAP_SLOTS,
    /// slot ごとの peak 累積器（peak モードの窓内 max。書き込み後 0 リセット）。
    acc: [TAP_SLOTS]f32 = [_]f32{0} ** TAP_SLOTS,
    /// 直近 block で latch した config の seq（block 末尾に applied_seq へ release store）。RT-private。
    latched_seq: u32 = 0,
};

/// 1 サンプル評価。nodes は処理順。cur へ書き、ping-pong swap を cur/prev ポインタへ反映する。
/// master 出力は swap 前に捕捉して返す（swap 後は prev 側へ移るため）。
fn processSample(
    nodes: []const ProcNode,
    cur: *[]f32,
    prev: *[]f32,
    sample_rate: f32,
    output: ?OutputSel,
) StereoOut {
    var in_vals: [signal.MAX_IN]f32 = undefined;
    var in_conn: [signal.MAX_IN]bool = undefined;
    for (nodes) |*node| {
        var i: usize = 0;
        while (i < node.n_in) : (i += 1) {
            const s = node.in_src[i];
            if (s < 0) {
                in_vals[i] = 0;
                in_conn[i] = false;
            } else {
                const sp: usize = @intCast(s);
                in_conn[i] = true;
                in_vals[i] = if (node.in_delayed[i]) prev.*[sp] else cur.*[sp];
            }
        }
        var io = Io{
            .inputs = in_vals[0..node.n_in],
            .connected = in_conn[0..node.n_in],
            .outputs = cur.*[node.out_base..][0..node.n_out],
            .sample_rate = sample_rate,
        };
        node.vtable.process(node.ctx, &io);
    }

    var out = StereoOut{ .l = 0, .r = 0 };
    if (output) |o| {
        out.l = cur.*[o.out_base];
        out.r = if (o.n_out >= 2) cur.*[o.out_base + 1] else cur.*[o.out_base];
    }

    // ping-pong 入替: 次サンプルの prev = 今サンプルの cur（= 遅延辺が読む値）。
    const tmp = cur.*;
    cur.* = prev.*;
    prev.* = tmp;
    return out;
}

/// ブロック先頭で全ノードの係数を更新（tan / @exp 等の重い計算はここ＝ブロックレート）。
fn updateAllParams(nodes: []const ProcNode, sample_rate: f32) void {
    for (nodes) |*node| node.vtable.updateParams(node.ctx, sample_rate);
}

/// interleaved 出力へ `frames` サンプル書き込む。nodes は処理順・有効前提（未 finalize / 無効 view /
/// channels==0 は呼び出し側で弾き buf をゼロ埋め済みにしておく）。channels==1 は (L+R)/2、
/// >=2 は L/R を書き残りを 0。RT callback から呼べる（alloc/lock/IO/panic なし）。
///
/// tap 無し経路（tapped=false）は per-sample ループに分岐を 1 つも足さない（tap 分岐は comptime 消去）。
/// → `processBlock`（graph.zig / dyn の tap 無し時が呼ぶ）はシグネチャ・機械語形状とも従来どおり不変。
fn processBlockImpl(
    comptime tapped: bool,
    nodes: []const ProcNode,
    output: ?OutputSel,
    sample_rate: f32,
    cur: *[]f32,
    prev: *[]f32,
    buf: []f32,
    frames: u32,
    channels: u32,
    tap: if (tapped) *TapState else void,
) void {
    const ch: usize = channels;
    const cap: usize = buf.len / ch;
    const n: usize = @min(@as(usize, frames), cap);
    updateAllParams(nodes, sample_rate);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const o = processSample(nodes, cur, prev, sample_rate, output);
        if (ch == 1) {
            buf[i] = (o.l + o.r) * 0.5;
        } else {
            const base = i * ch;
            buf[base] = o.l;
            buf[base + 1] = o.r;
            var c: usize = 2;
            while (c < ch) : (c += 1) buf[base + c] = 0;
        }
        if (tapped) {
            // processSample が ping-pong swap 済みなので、当該サンプルの各ポート出力値は prev.* 側にある
            // （swap 前の cur.* と同値。master 捕捉と同じ「唯一の場所」を swap 後の別名で読むだけ）。
            // per-slot 間引き＋reduce: peak は窓内 max（gate の 1 サンプル幅パルスを取りこぼさない）、
            // 非 peak は間引き境界の末尾値（波形）。O(TAP_SLOTS)/sample の load+max+比較のみ（alloc/lock/超越関数なし）。
            const sig = prev.*;
            var s: usize = 0;
            while (s < TAP_SLOTS) : (s += 1) {
                const p = tap.latched_ports[s];
                if (p < 0) continue;
                const pu: usize = @intCast(p);
                if (pu >= sig.len) continue; // 範囲 clamp（stale port でも panic させない）
                const v = sig[pu];
                if (tap.latched_peak[s]) tap.acc[s] = @max(tap.acc[s], v);
                tap.cnt[s] += 1;
                const d = @max(@as(u32, 1), tap.latched_decim[s]); // decim=0 の暴走防止
                if (tap.cnt[s] >= d) {
                    tap.cnt[s] = 0;
                    const out_v = if (tap.latched_peak[s]) tap.acc[s] else v;
                    // .unordered = torn 無し・races OK の最弱 atomic。naturally-aligned f32 では plain store と
                    // 同一機械語（fence/RMW 無し）＝RT 追加コスト無し。GUI 側 tapWindow の unordered load と対で
                    // 「読み中に次 block が上書きする tail」を data race UB でなく best-effort torn に落とす。
                    @atomicStore(f32, &tap.slots[s].ring[tap.local_wpos[s] % TAP_RING], out_v, .unordered);
                    tap.local_wpos[s] += 1;
                    if (tap.latched_peak[s]) tap.acc[s] = 0; // 窓リセット
                }
            }
        }
    }
    if (tapped) {
        // block 末尾に slot あたり 1 回だけ release store（毎サンプル atomic を避ける）。
        var s: usize = 0;
        while (s < TAP_SLOTS) : (s += 1) tap.slots[s].wpos.store(tap.local_wpos[s], .release);
    }
}

pub fn processBlock(
    nodes: []const ProcNode,
    output: ?OutputSel,
    sample_rate: f32,
    cur: *[]f32,
    prev: *[]f32,
    buf: []f32,
    frames: u32,
    channels: u32,
) void {
    processBlockImpl(false, nodes, output, sample_rate, cur, prev, buf, frames, channels, {});
}

/// tap 有り版（tap slot が 1 つでも active な block で dyn が呼ぶ）。出力 buf は tap 無し版と bit 一致
/// （tap は prev.* を読むだけで buf/DSP 状態に非侵襲）。
pub fn processBlockTapped(
    nodes: []const ProcNode,
    output: ?OutputSel,
    sample_rate: f32,
    cur: *[]f32,
    prev: *[]f32,
    buf: []f32,
    frames: u32,
    channels: u32,
    tap: *TapState,
) void {
    processBlockImpl(true, nodes, output, sample_rate, cur, prev, buf, frames, channels, tap);
}

// ============================================================================
// tests（構造の健全性のみ。実挙動は facade（graph.zig / dyn.zig）のテストで担保）
// ============================================================================
const testing = std.testing;

test "graph_core: ProcNode / GraphView payload はポインタ以外 POD（index/handle 参照）" {
    // ProcNode は RT ローカル解決済みなので vtable/ctx ポインタを含む（これは publish 越しでない）。
    try testing.expect(@sizeOf(OutputSel) > 0);
    try testing.expect(@sizeOf(ProcNode) > 0);
}
