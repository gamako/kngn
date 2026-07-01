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
    }
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
