//! libs/modular: 動的グラフエンジン + RT 安全ライブ再配線（TASK-40.6.1）。
//!
//! 設計の正: docs/plans/modular-synth-plan.md §4.3/§4.3.1。5 テネット（性能目的の Zig 的メモリ設計）:
//!   1. トポロジ/DSP 状態分離: publish で RT へ渡るのは GraphView（接続・order・handle＝数 KB）だけ。
//!      DSP 状態（DelayLine 256KB/個・Reverb・位相・フィルタメモリ）は RT 所有プールに据え置き publish に載せない。
//!   2. 型別固定プール: 全モジュールを 1 つの union(enum) にせず（最大メンバ DelayFx≈256KB × [N] で膨れる）、
//!      型別の固定配列プール（安いモジュール多め / DelayFx・ReverbFx は少数）。配列は動かさず ctx 安定・RT alloc 無し。
//!   3. POD View + handle 参照: GraphView はポインタを含まない固定インライン配列の値型。RT は handle から
//!      安定レジストリ（instances）で vtable/ctx/out_base/n_in/n_out を解決。
//!   4. RT 経路ゼロアロケーション: topo sort・サイクル検出・View 構築は全て main 側。processBlock は
//!      allocator を持たず stack scratch のみ。
//!   5. ポート id 固定割当: instance slot i に出力 port id 範囲 [i*MAX_OUT..) を恒久割当。port_owner は
//!      port_id/MAX_OUT で導出。再配線をまたいでポート位置が安定し遅延辺の前サンプル値も保つ。
//!
//! RT 安全ライブ再配線:
//!   - publish は SPSC triple-buffer（3 枚）。連続 publish でも producer が consumer read slot を書かない
//!     （3 index が {0,1,2} 置換）→ torn read 無し・latest-wins・非ブロッキング。
//!   - handle/pool-slot 再利用は RCU 的 grace: removeModule は RT-read field を破壊せず retired 印+retire_gen。
//!     consumed_gen（RT が latch した view の gen）>= retire_gen を満たすまで再利用禁止（旧 view 処理完了保証）。
//!
//! 自己参照（instances.ctx が pools を指す）ため **heap 確保しムーブしない**（create/destroy）。
//! signal/pool/view を inline 固定確保し render 経路は allocator を一切持たない。

const std = @import("std");
const signal = @import("signal.zig");
const graph_core = @import("graph_core.zig");
const modules = @import("modules.zig");

const PortKind = signal.PortKind;
const ProcNode = graph_core.ProcNode;
const MAX_IN = signal.MAX_IN;
const MAX_OUT = signal.MAX_OUT;

/// handle / instance / View 幅・port stride の基準。
pub const MAX_MODULES = 48;
/// signal バッファ長（ポート id 固定割当 slot*MAX_OUT）。
pub const MAX_PORTS: usize = @as(usize, MAX_MODULES) * MAX_OUT;

pub const Handle = u16;

/// モジュール種別（全型を列挙）。KindType / poolCap / poolArray がこの enum で分岐する。
pub const ModuleKind = enum {
    vco,
    vca,
    env_gen,
    vcf,
    mixer,
    output,
    clock,
    clock_divider,
    euclid,
    quantizer,
    step_seq,
    lfo,
    kick,
    hat,
    perc_env,
    random,
    turing,
    clap,
    chord_pad,
    saturator,
    bitcrusher,
    delay,
    reverb,
    vinyl,
    wow_flutter,
    sidechain,
};

/// kind → 具体型。
pub fn KindType(comptime k: ModuleKind) type {
    return switch (k) {
        .vco => modules.Vco,
        .vca => modules.Vca,
        .env_gen => modules.EnvGen,
        .vcf => modules.Vcf,
        .mixer => modules.Mixer,
        .output => modules.Output,
        .clock => modules.Clock,
        .clock_divider => modules.ClockDivider,
        .euclid => modules.EuclideanSeq,
        .quantizer => modules.Quantizer,
        .step_seq => modules.StepSeq,
        .lfo => modules.Lfo,
        .kick => modules.Kick,
        .hat => modules.Hat,
        .perc_env => modules.PercEnv,
        .random => modules.Random,
        .turing => modules.TuringMachine,
        .clap => modules.Clap,
        .chord_pad => modules.ChordPad,
        .saturator => modules.Saturator,
        .bitcrusher => modules.Bitcrusher,
        .delay => modules.DelayFx,
        .reverb => modules.ReverbFx,
        .vinyl => modules.VinylNoiseFx,
        .wow_flutter => modules.WowFlutterFx,
        .sidechain => modules.Sidechain,
    };
}

/// kind → プール容量（安いモジュール多め / delay・reverb は少数。合計は handle 空間より大きくてよいが
/// active 総数は MAX_MODULES 上限）。
pub fn poolCap(comptime k: ModuleKind) usize {
    return switch (k) {
        .vco, .vca, .env_gen => 12,
        // step_seq は 4→8（TASK-40.7.2: DrumMachine×2=4 + BassMachine=1 で cap4 が尽きるため。小型 struct で Pools 増は微小）。
        .vcf, .mixer, .lfo, .step_seq => 8,
        .euclid, .perc_env, .random => 6,
        .clock, .clock_divider, .quantizer, .kick, .hat, .turing, .clap, .chord_pad, .saturator, .bitcrusher, .sidechain => 4,
        .output, .delay, .reverb, .vinyl, .wow_flutter => 2,
    };
}

/// 型別固定プール（明示フィールド。comptime tuple 生成は避け compile 安全・可読優先）。DSP 状態常駐（publish 非対象）。
const Pools = struct {
    vco: [poolCap(.vco)]modules.Vco,
    vca: [poolCap(.vca)]modules.Vca,
    env_gen: [poolCap(.env_gen)]modules.EnvGen,
    vcf: [poolCap(.vcf)]modules.Vcf,
    mixer: [poolCap(.mixer)]modules.Mixer,
    output: [poolCap(.output)]modules.Output,
    clock: [poolCap(.clock)]modules.Clock,
    clock_divider: [poolCap(.clock_divider)]modules.ClockDivider,
    euclid: [poolCap(.euclid)]modules.EuclideanSeq,
    quantizer: [poolCap(.quantizer)]modules.Quantizer,
    step_seq: [poolCap(.step_seq)]modules.StepSeq,
    lfo: [poolCap(.lfo)]modules.Lfo,
    kick: [poolCap(.kick)]modules.Kick,
    hat: [poolCap(.hat)]modules.Hat,
    perc_env: [poolCap(.perc_env)]modules.PercEnv,
    random: [poolCap(.random)]modules.Random,
    turing: [poolCap(.turing)]modules.TuringMachine,
    clap: [poolCap(.clap)]modules.Clap,
    chord_pad: [poolCap(.chord_pad)]modules.ChordPad,
    saturator: [poolCap(.saturator)]modules.Saturator,
    bitcrusher: [poolCap(.bitcrusher)]modules.Bitcrusher,
    delay: [poolCap(.delay)]modules.DelayFx,
    reverb: [poolCap(.reverb)]modules.ReverbFx,
    vinyl: [poolCap(.vinyl)]modules.VinylNoiseFx,
    wow_flutter: [poolCap(.wow_flutter)]modules.WowFlutterFx,
    sidechain: [poolCap(.sidechain)]modules.Sidechain,
};

/// RT が読む安定レジストリ field（init 後、対応 handle が active/retired の間は不変）。
const Instance = struct {
    vtable: *const signal.VTable = undefined,
    ctx: *anyopaque = undefined,
    n_in: u8 = 0,
    n_out: u8 = 0,
    /// signal バッファ上の出力ポート先頭 index（= handle * MAX_OUT）。
    out_base: u32 = 0,
    in_kinds: [MAX_IN]PortKind = undefined,
    out_kinds: [MAX_OUT]PortKind = undefined,
};

/// ライフサイクル metadata（main のみ触る。RT は読まない ＝ Instance と分離）。
const SlotMeta = struct {
    active: bool = false,
    retired: bool = false,
    kind: ModuleKind = .vco,
    pool_idx: u16 = 0,
    /// retired にした時、handle が消える最初の view の gen（consumed_gen>=これ で再利用可）。
    retire_gen: u64 = 0,
};

const Color = enum(u8) { unvisited, visiting, done };

/// RT へ publish する POD グラフ記述（ポインタ皆無・index/handle 参照のみ）。値コピーで publish。
pub const GraphView = struct {
    gen: u64 = 0,
    node_count: u16 = 0,
    /// 処理順の handle 列（長さ = node_count）。
    order: [MAX_MODULES]u16 = [_]u16{0} ** MAX_MODULES,
    /// handle で index する各入力ポートの接続元グローバル出力ポート id（未接続 = -1）。
    in_src: [MAX_MODULES][MAX_IN]i32 = [_][MAX_IN]i32{[_]i32{-1} ** MAX_IN} ** MAX_MODULES,
    /// handle で index する各入力ポートのサイクル遅延辺フラグ。
    in_delayed: [MAX_MODULES][MAX_IN]bool = [_][MAX_IN]bool{[_]bool{false} ** MAX_IN} ** MAX_MODULES,
    /// master 出力 handle（-1 = 無し）。
    output: i32 = -1,

    pub fn empty() GraphView {
        return .{};
    }
};

// ============================================================================
// SPSC triple-buffer（3 枚）。producer=main / consumer=RT。連続 publish 安全・非ブロッキング・latest-wins。
// shared = index(下位 2bit) | FRESH_BIT。3 index {write_idx, read_idx, shared&IDX} は常に {0,1,2} の置換で、
// producer は read slot を絶対書かない → torn read 無し。
// ============================================================================
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        const FRESH: u8 = 0x80;
        const IDX_MASK: u8 = 0x03;

        bufs: [3]T,
        shared: std.atomic.Value(u8),
        write_idx: u8, // producer-private
        read_idx: u8, // consumer-private

        pub fn init(initial: T) Self {
            return .{
                .bufs = .{ initial, initial, initial },
                .shared = std.atomic.Value(u8).init(2), // slot2 published(no fresh) / write=0 / read=1
                .write_idx = 0,
                .read_idx = 1,
            };
        }

        /// producer(main): private write slot に書いてから ready と交換（never block）。
        pub fn publish(self: *Self, value: T) void {
            self.bufs[self.write_idx] = value;
            const new: u8 = self.write_idx | FRESH;
            const old = self.shared.swap(new, .acq_rel);
            self.write_idx = old & IDX_MASK;
        }

        /// consumer(RT): fresh があれば read slot を ready と交換して最新を latch、無ければ現 view 維持。
        pub fn acquire(self: *Self) *const T {
            const s = self.shared.load(.acquire);
            if (s & FRESH != 0) {
                const old = self.shared.swap(self.read_idx, .acq_rel);
                self.read_idx = old & IDX_MASK;
            }
            return &self.bufs[self.read_idx];
        }

        /// テスト用: 3 index が {0,1,2} の置換であることを確認（h1 不変条件）。
        pub fn indicesArePermutation(self: *const Self) bool {
            const a = self.write_idx & IDX_MASK;
            const b = self.read_idx & IDX_MASK;
            const c = self.shared.load(.monotonic) & IDX_MASK;
            return a != b and b != c and a != c and a < 3 and b < 3 and c < 3;
        }
    };
}

// ============================================================================
// DynGraph
// ============================================================================
pub const Error = error{
    TooManyModules, // handle 空間（MAX_MODULES）枯渇
    PoolFull, // 当該 kind のプール枯渇
    BadNodeIndex,
    BadPortIndex,
    InputAlreadyConnected,
    PortKindMismatch,
} || std.mem.Allocator.Error;

pub const DynGraph = struct {
    allocator: std.mem.Allocator, // create/destroy のみに使用（render 経路は触らない）
    sample_rate: f32,

    pools: Pools,
    instances: [MAX_MODULES]Instance,
    slots: [MAX_MODULES]SlotMeta,

    // staging（main 編集）。stage_in_src は handle で index。
    stage_in_src: [MAX_MODULES][MAX_IN]i32,
    stage_output: i32,

    // publish 世代 + RT が latch した gen。
    gen: u64,
    consumed_gen: std.atomic.Value(u64),
    mailbox: Mailbox(GraphView),
    /// main 側の最新 publish コピー（テスト introspection 用。RT は読まない）。
    last_published: GraphView,

    // signal ping-pong（inline 固定確保。cur/prev は sig_a/sig_b を指すスライスで swap）。
    sig_a: [MAX_PORTS]f32,
    sig_b: [MAX_PORTS]f32,
    cur: []f32,
    prev: []f32,

    // TASK-40.8 D: ポート別ミニ oscilloscope の per-port tap。
    // cache_line 分離: GUI 書き領域（tap_mailbox）と RT 書き領域（tap: applied_seq/wpos/ring）を別ラインへ。
    // false sharing の実害ペアは「GUI 書き × RT 書き」なので、この 2 ブロックを分ければ足りる
    // （slot 間 wpos は単一 RT スレッドのみ書き・GUI は読みのみなので同居可）。
    tap_mailbox: Mailbox(graph_core.TapConfig) align(std.atomic.cache_line),
    tap: graph_core.TapState align(std.atomic.cache_line),

    /// heap 確保して初期化（自己参照ポインタのためムーブ禁止）。
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) Error!*DynGraph {
        const self = try allocator.create(DynGraph);
        self.* = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .pools = undefined, // slot は activate 時に書くので未使用領域は読まない
            .instances = [_]Instance{.{}} ** MAX_MODULES,
            .slots = [_]SlotMeta{.{}} ** MAX_MODULES,
            .stage_in_src = [_][MAX_IN]i32{[_]i32{-1} ** MAX_IN} ** MAX_MODULES,
            .stage_output = -1,
            .gen = 0,
            .consumed_gen = std.atomic.Value(u64).init(0),
            .mailbox = Mailbox(GraphView).init(GraphView.empty()),
            .last_published = GraphView.empty(),
            .sig_a = [_]f32{0} ** MAX_PORTS,
            .sig_b = [_]f32{0} ** MAX_PORTS,
            .cur = undefined,
            .prev = undefined,
            .tap_mailbox = Mailbox(graph_core.TapConfig).init(.{}),
            .tap = .{},
        };
        self.cur = self.sig_a[0..];
        self.prev = self.sig_b[0..];
        return self;
    }

    pub fn destroy(self: *DynGraph) void {
        const a = self.allocator;
        a.destroy(self);
    }

    fn poolArray(self: *DynGraph, comptime k: ModuleKind) *[poolCap(k)]KindType(k) {
        return switch (k) {
            .vco => &self.pools.vco,
            .vca => &self.pools.vca,
            .env_gen => &self.pools.env_gen,
            .vcf => &self.pools.vcf,
            .mixer => &self.pools.mixer,
            .output => &self.pools.output,
            .clock => &self.pools.clock,
            .clock_divider => &self.pools.clock_divider,
            .euclid => &self.pools.euclid,
            .quantizer => &self.pools.quantizer,
            .step_seq => &self.pools.step_seq,
            .lfo => &self.pools.lfo,
            .kick => &self.pools.kick,
            .hat => &self.pools.hat,
            .perc_env => &self.pools.perc_env,
            .random => &self.pools.random,
            .turing => &self.pools.turing,
            .clap => &self.pools.clap,
            .chord_pad => &self.pools.chord_pad,
            .saturator => &self.pools.saturator,
            .bitcrusher => &self.pools.bitcrusher,
            .delay => &self.pools.delay,
            .reverb => &self.pools.reverb,
            .vinyl => &self.pools.vinyl,
            .wow_flutter => &self.pools.wow_flutter,
            .sidechain => &self.pools.sidechain,
        };
    }

    fn isActive(self: *const DynGraph, h: Handle) bool {
        return h < MAX_MODULES and self.slots[h].active;
    }

    /// grace 済み（consumed_gen>=retire_gen）の retired slot を完全 free へ戻す（reuse 前に呼ぶ）。
    fn reclaimRetired(self: *DynGraph) void {
        const cg = self.consumed_gen.load(.acquire);
        for (&self.slots) |*s| {
            if (s.retired and cg >= s.retire_gen) s.retired = false;
        }
    }

    /// live(active||retired)な handle が pool(kind,idx) を占有しているか。
    fn poolIdxFree(self: *const DynGraph, k: ModuleKind, idx: u16) bool {
        for (self.slots) |s| {
            if ((s.active or s.retired) and s.kind == k and s.pool_idx == idx) return false;
        }
        return true;
    }

    fn findFreeHandle(self: *const DynGraph) ?Handle {
        var i: Handle = 0;
        while (i < MAX_MODULES) : (i += 1) {
            if (!self.slots[i].active and !self.slots[i].retired) return i;
        }
        return null;
    }

    /// モジュールを追加し handle を返す。value を pool slot にコピー（activate 時の遅延リセット）し、
    /// signal port 範囲をクリア、spec() から RT-read field を焼く。DSP 状態は他 slot を触らない。
    pub fn add(self: *DynGraph, comptime k: ModuleKind, value: KindType(k)) Error!Handle {
        self.reclaimRetired();
        const h = self.findFreeHandle() orelse return Error.TooManyModules;
        const cap = poolCap(k);
        var pidx: u16 = 0;
        while (pidx < cap) : (pidx += 1) {
            if (self.poolIdxFree(k, pidx)) break;
        }
        if (pidx >= cap) return Error.PoolFull;

        const arr = self.poolArray(k);
        arr[pidx] = value; // 状態リセット（DSP 状態を既定へ）
        const base: usize = @as(usize, h) * MAX_OUT;
        @memset(self.sig_a[base..][0..MAX_OUT], 0); // 旧モジュールの残留出力を漏らさない
        @memset(self.sig_b[base..][0..MAX_OUT], 0);

        const sp = arr[pidx].spec();
        var inst = &self.instances[h];
        inst.vtable = sp.vtable;
        inst.ctx = sp.ctx;
        inst.n_in = @intCast(sp.in_kinds.len);
        inst.n_out = @intCast(sp.out_kinds.len);
        inst.out_base = @intCast(base);
        for (sp.in_kinds, 0..) |kk, i| inst.in_kinds[i] = kk;
        for (sp.out_kinds, 0..) |kk, i| inst.out_kinds[i] = kk;

        self.slots[h] = .{ .active = true, .retired = false, .kind = k, .pool_idx = pidx };
        self.stage_in_src[h] = [_]i32{-1} ** MAX_IN;
        return h;
    }

    /// モジュールを削除（retire）。RT-read field は破壊せず、staging の接続と output をクリアし、
    /// retire_gen を次 publish の gen に設定（grace 成立まで handle/pool は再利用されない）。
    pub fn removeModule(self: *DynGraph, h: Handle) void {
        if (!self.isActive(h)) return;
        self.slots[h].active = false;
        self.slots[h].retired = true;
        self.slots[h].retire_gen = self.gen + 1; // 次 publish の view から handle が消える

        self.stage_in_src[h] = [_]i32{-1} ** MAX_IN; // この handle の入力接続
        const base: i32 = @intCast(self.instances[h].out_base);
        const span: i32 = @intCast(MAX_OUT);
        for (&self.stage_in_src) |*ins| { // この handle の出力を参照する他入力
            for (ins) |*src| {
                if (src.* >= base and src.* < base + span) src.* = -1;
            }
        }
        if (self.stage_output == @as(i32, h)) self.stage_output = -1;
    }

    /// src_node.out → dst_node.in を接続（種別一致・単一接続=既接続はエラー）。staging のみ編集。
    pub fn connect(self: *DynGraph, src_h: Handle, src_out: usize, dst_h: Handle, dst_in: usize) Error!void {
        if (!self.isActive(src_h) or !self.isActive(dst_h)) return Error.BadNodeIndex;
        const si = &self.instances[src_h];
        const di = &self.instances[dst_h];
        if (src_out >= si.n_out or dst_in >= di.n_in) return Error.BadPortIndex;
        if (si.out_kinds[src_out] != di.in_kinds[dst_in]) return Error.PortKindMismatch;
        if (self.stage_in_src[dst_h][dst_in] != -1) return Error.InputAlreadyConnected;
        self.stage_in_src[dst_h][dst_in] = @intCast(si.out_base + @as(u32, @intCast(src_out)));
    }

    pub fn disconnect(self: *DynGraph, dst_h: Handle, dst_in: usize) void {
        if (dst_h < MAX_MODULES and dst_in < MAX_IN) self.stage_in_src[dst_h][dst_in] = -1;
    }

    pub fn setOutput(self: *DynGraph, h: Handle) void {
        self.stage_output = @intCast(h);
    }

    /// DFS（依存を先に積む）。visiting 中の依存先＝back edge を遅延辺として印付ける（graph.zig と同方針）。
    fn dfs(
        self: *DynGraph,
        u: Handle,
        colors: *[MAX_MODULES]Color,
        in_delayed: *[MAX_MODULES][MAX_IN]bool,
        order: *[MAX_MODULES]u16,
        order_len: *usize,
    ) void {
        colors[u] = .visiting;
        const n_in = self.instances[u].n_in;
        var i: usize = 0;
        while (i < n_in) : (i += 1) {
            const s = self.stage_in_src[u][i];
            if (s < 0) continue;
            const owner: Handle = @intCast(@as(usize, @intCast(s)) / MAX_OUT);
            if (!self.slots[owner].active) continue; // dangling 防御（removeModule で通常はクリア済み）
            if (owner == u) {
                in_delayed[u][i] = true; // self-loop は遅延
                continue;
            }
            switch (colors[owner]) {
                .unvisited => self.dfs(owner, colors, in_delayed, order, order_len),
                .visiting => in_delayed[u][i] = true, // back edge → 遅延
                .done => {},
            }
        }
        colors[u] = .done;
        order[order_len.*] = u;
        order_len.* += 1;
    }

    /// staging を topo sort + サイクル検出 + master 検証して GraphView を焼き、triple-buffer へ publish。
    /// 非 RT。per-call heap alloc なし（scratch は stack）。
    pub fn publish(self: *DynGraph) Error!void {
        var colors: [MAX_MODULES]Color = undefined;
        for (0..MAX_MODULES) |i| colors[i] = if (self.slots[i].active) .unvisited else .done;

        var view = GraphView{};
        var order_len: usize = 0;
        var i: usize = 0;
        while (i < MAX_MODULES) : (i += 1) {
            if (colors[i] == .unvisited) self.dfs(@intCast(i), &colors, &view.in_delayed, &view.order, &order_len);
        }
        view.node_count = @intCast(order_len);

        // master 出力の妥当性（非 RT でここで検証。RT では panic させない）。
        var out: i32 = -1;
        if (self.stage_output >= 0) {
            const oh: Handle = @intCast(self.stage_output);
            if (!self.isActive(oh) or self.instances[oh].n_out < 1) return Error.BadNodeIndex;
            out = self.stage_output;
        }
        view.output = out;
        view.in_src = self.stage_in_src; // handle で index（active 以外の行は未使用）
        view.gen = self.gen + 1;

        self.mailbox.publish(view);
        self.last_published = view;
        self.gen += 1;
    }

    /// RT: 最新 view を latch → gen を記録 → handle をレジストリで resolve → graph_core。
    /// alloc/lock/IO/panic/sort なし。未 publish/空 view/channels==0 はゼロ埋め。
    pub fn processBlock(self: *DynGraph, buf: []f32, frames: u32, channels: u32) void {
        const view = self.mailbox.acquire();
        self.consumed_gen.store(view.gen, .release);
        // D: tap config を latch（block あたり 1 回）。差し替わった slot は local_wpos/wpos をリセットして
        // 旧 port の残留サンプルを新 port の窓へ混ぜない。空/無チャンネル時も latch と applied_seq store は行う
        // （GUI の描画 gate が止まらないように）。
        const any_tap = self.latchTapConfig();
        if (view.node_count == 0 or channels == 0) {
            @memset(buf, 0);
            self.tap.applied_seq.store(self.tap.latched_seq, .release);
            return;
        }
        var procs: [MAX_MODULES]ProcNode = undefined;
        var k: usize = 0;
        while (k < view.node_count) : (k += 1) {
            const h = view.order[k];
            const inst = &self.instances[h];
            procs[k] = .{
                .vtable = inst.vtable,
                .ctx = inst.ctx,
                .n_in = inst.n_in,
                .n_out = inst.n_out,
                .out_base = inst.out_base,
                .in_src = view.in_src[h],
                .in_delayed = view.in_delayed[h],
            };
        }
        const out_sel: ?graph_core.OutputSel = if (view.output >= 0) blk: {
            const oh: Handle = @intCast(view.output);
            break :blk .{ .out_base = self.instances[oh].out_base, .n_out = self.instances[oh].n_out };
        } else null;
        // block 単位の分岐 1 回のみ: tap slot が 1 つでも active なら tapped 版、なければ従来版（機械語不変）。
        if (any_tap) {
            graph_core.processBlockTapped(procs[0..view.node_count], out_sel, self.sample_rate, &self.cur, &self.prev, buf, frames, channels, &self.tap);
        } else {
            graph_core.processBlock(procs[0..view.node_count], out_sel, self.sample_rate, &self.cur, &self.prev, buf, frames, channels);
        }
        // block 末尾に latch 済み config の seq を release store（1 store/block。GUI 描画 gate）。
        self.tap.applied_seq.store(self.tap.latched_seq, .release);
    }

    /// tap config（GUI publish）を acquire して latch する。差し替わった slot は local_wpos=0 + wpos=0 に
    /// リセット（旧 port の残留を「無し」扱い）。active な tap slot が 1 つでもあれば true。非 RT alloc/lock なし。
    fn latchTapConfig(self: *DynGraph) bool {
        const cfg = self.tap_mailbox.acquire();
        self.tap.latched_seq = cfg.seq;
        var any = false;
        var s: usize = 0;
        while (s < graph_core.TAP_SLOTS) : (s += 1) {
            const p = cfg.ports[s];
            if (p != self.tap.latched_ports[s]) {
                self.tap.latched_ports[s] = p;
                self.tap.local_wpos[s] = 0;
                self.tap.cnt[s] = 0;
                self.tap.acc[s] = 0;
                self.tap.slots[s].wpos.store(0, .release); // GUI へ即「空」を見せる
            }
            // port の種別は固定なので decim/peak は port 不変なら変わらない（毎 block latch でコストは軽微）。
            self.tap.latched_decim[s] = cfg.decim[s];
            self.tap.latched_peak[s] = cfg.peak[s];
            if (p >= 0 and @as(usize, @intCast(p)) < MAX_PORTS) any = true;
        }
        return any;
    }

    // --- テスト用イントロスペクション / 非 RT config / live atomic param ---
    /// live pool slot（RT が処理する実インスタンス。publish payload 非対象の DSP 常駐状態）への ptr を返す。
    ///
    /// 用途 2 種:
    ///   1. 非 RT・publish 前 or grace 期間中の初期設定（従来）。
    ///   2. **atomic 化された field に限り稼働中の atomic アクセス**（TASK-40.7.2 で具体化した「live param の
    ///      atomic 境界」）。例: StepSeq の mask/step は `@atomicLoad`/`@atomicStore(.monotonic)` 化済みなので、
    ///      GUI(メインスレッド)の store と RT `process` の load が同一 live インスタンスを介す正しい cross-thread
    ///      チャネルになる（ptrOf が返すのはまさに RT が処理する pool slot だから）。
    ///
    /// **非 atomic field への稼働中書き込みは引き続き禁止**（RT 読みと torn する）。active member のみに使う
    /// （台帳同期で removeModule 済み handle には使わない）。関数シグネチャ・戻り値は不変。
    pub fn ptrOf(self: *DynGraph, comptime k: ModuleKind, h: Handle) *KindType(k) {
        return &self.poolArray(k)[self.slots[h].pool_idx];
    }
    pub fn activeCount(self: *const DynGraph) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.active) n += 1;
        }
        return n;
    }
    pub fn consumedGen(self: *const DynGraph) u64 {
        return self.consumed_gen.load(.acquire);
    }
    pub fn currentView(self: *const DynGraph) GraphView {
        return self.last_published;
    }
    pub fn isDelayed(self: *const DynGraph, h: Handle, in_port: usize) bool {
        return self.last_published.in_delayed[h][in_port];
    }

    // --- 描画/probe 用の読み取り専用イントロスペクション（範囲外は null/0。無条件 index で落とさない）---
    pub fn slotActive(self: *const DynGraph, h: Handle) bool {
        return h < MAX_MODULES and self.slots[h].active;
    }
    pub fn kindOf(self: *const DynGraph, h: Handle) ?ModuleKind {
        if (!self.slotActive(h)) return null;
        return self.slots[h].kind;
    }
    pub fn nIn(self: *const DynGraph, h: Handle) u8 {
        if (!self.slotActive(h)) return 0;
        return self.instances[h].n_in;
    }
    pub fn nOut(self: *const DynGraph, h: Handle) u8 {
        if (!self.slotActive(h)) return 0;
        return self.instances[h].n_out;
    }
    pub fn inKindOf(self: *const DynGraph, h: Handle, i: usize) ?PortKind {
        if (!self.slotActive(h) or i >= self.instances[h].n_in) return null;
        return self.instances[h].in_kinds[i];
    }
    pub fn outKindOf(self: *const DynGraph, h: Handle, j: usize) ?PortKind {
        if (!self.slotActive(h) or j >= self.instances[h].n_out) return null;
        return self.instances[h].out_kinds[j];
    }

    // --- TASK-40.8 A: ポート活性度（RT 影響ゼロの best-effort torn read）---
    /// 出力ポート (h, out) の現在の信号レベル ≒ max(|sig_a[p]|, |sig_b[p]|)。RT が書く f32 を非同期に読む
    /// best-effort（ping-pong のどちらが最新かは不定だが活性度表示には十分。40.6.1 の「signal の GUI 読みは
    /// torn 可」の範囲）。`.unordered` atomic load で torn を避けつつ RT 経路は不変（GUI 側のみ）。
    /// 範囲外/非 active は 0（無条件 index で落とさない）。
    pub fn sigLevel(self: *const DynGraph, h: Handle, out: usize) f32 {
        if (h >= MAX_MODULES or out >= MAX_OUT or !self.slots[h].active) return 0;
        const p = @as(usize, h) * MAX_OUT + out;
        const a = @abs(@atomicLoad(f32, &self.sig_a[p], .unordered));
        const b = @abs(@atomicLoad(f32, &self.sig_b[p], .unordered));
        return @max(a, b);
    }

    // --- TASK-40.8 D: per-port tap（GUI 側 API）---
    /// GUI→RT: tap 対象 port 割当を publish（triple-buffer・torn 無し・latest-wins・非ブロッキング）。
    pub fn publishTapConfig(self: *DynGraph, cfg: graph_core.TapConfig) void {
        self.tap_mailbox.publish(cfg);
    }
    /// RT が最後に latch・適用した config の seq（GUI の描画 gate）。
    pub fn tapAppliedSeq(self: *const DynGraph) u32 {
        return self.tap.applied_seq.load(.acquire);
    }
    /// slot の書き込み総サンプル数（acquire。これ以下の ring 書き込みは可視）。
    pub fn tapWpos(self: *const DynGraph, slot: usize) u32 {
        if (slot >= graph_core.TAP_SLOTS) return 0;
        return self.tap.slots[slot].wpos.load(.acquire);
    }
    /// slot の直近窓（最大 out.len）を oldest→newest で out へコピーし、コピー数を返す。
    /// wpos acquire までの ring 書き込みは可視。読み中に RT が上書きする tail の torn は表示グリッチのみ許容。
    pub fn tapWindow(self: *const DynGraph, slot: usize, out: []f32) usize {
        if (slot >= graph_core.TAP_SLOTS) return 0;
        const w = self.tap.slots[slot].wpos.load(.acquire);
        const avail = @min(@as(usize, w), graph_core.TAP_RING);
        const count = @min(avail, out.len);
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const abs = @as(usize, w) - count + k; // count<=avail<=w なのでアンダーフロー無し
            // RT の unordered store と対の unordered load（torn 無し・races OK・plain load と同一機械語）。
            out[k] = @atomicLoad(f32, &self.tap.slots[slot].ring[abs % graph_core.TAP_RING], .unordered);
        }
        return count;
    }

    // --- main 専用の preflight accessor（read-only・RT 非関与。TASK-40.7.1 macro.zig の preflight 用）---
    // publish/processBlock の RT 経路・RCU/triple-buffer 機構は一切変更しない。add() と同じ reclaim 条件
    // （live=active || (retired かつ consumed_gen < retire_gen)）を織り込んだ「今 add したら確保できる」
    // 数を返す（reclaimRetired 実行前でも add が実際に確保できる数と一致させる。非破壊で数えるだけ）。

    /// kind のプールに今 add したら確保できる空き数。
    pub fn poolFreeCount(self: *const DynGraph, comptime k: ModuleKind) usize {
        const cg = self.consumed_gen.load(.acquire);
        var used: usize = 0;
        for (self.slots) |s| {
            if (s.kind != k) continue;
            if (s.active or (s.retired and cg < s.retire_gen)) used += 1;
        }
        const cap = poolCap(k);
        return if (used >= cap) 0 else cap - used;
    }

    /// 今 add したら確保できる空き handle 数（MAX_MODULES 上限）。
    pub fn freeHandleCount(self: *const DynGraph) usize {
        const cg = self.consumed_gen.load(.acquire);
        var used: usize = 0;
        for (self.slots) |s| {
            if (s.active or (s.retired and cg < s.retire_gen)) used += 1;
        }
        return if (used >= MAX_MODULES) 0 else MAX_MODULES - used;
    }
};

/// union-to-largest の代理サイズ（全 kind の最大 @sizeOf × MAX_MODULES）。テスト（e）で比較。
pub fn unionToLargestSize() usize {
    comptime var biggest: usize = 0;
    inline for (std.meta.fields(ModuleKind)) |f| {
        const k: ModuleKind = @enumFromInt(f.value);
        const sz = @sizeOf(KindType(k));
        if (sz > biggest) biggest = sz;
    }
    return @as(usize, MAX_MODULES) * biggest;
}

pub fn poolsSize() usize {
    return @sizeOf(Pools);
}

// ============================================================================
// tests（display/audio 不要・test-modular に含む）
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

test "dyn(e): 型別プール < union 一律（union-to-largest 膨張の回避）" {
    // DelayFx(≈256KB) を全 slot に敷く union 代理より、実プール総量が十分小さい。
    try testing.expect(poolsSize() < unionToLargestSize());
    // 大差（少なくとも数倍）であることも確認。
    try testing.expect(poolsSize() * 2 < unionToLargestSize());
}

test "dyn(h1/h2): triple-buffer は連続 publish でも torn せず latest-wins・非 fresh は現 view 維持" {
    var mb = Mailbox(u32).init(0);
    try testing.expect(mb.indicesArePermutation());
    // 非 fresh consume は初期値維持
    try testing.expectEqual(@as(u32, 0), mb.acquire().*);
    // 連続 publish（consume 挟まず）でも置換不変・producer は read slot を書かない
    mb.publish(10);
    try testing.expect(mb.indicesArePermutation());
    mb.publish(20);
    try testing.expect(mb.indicesArePermutation());
    mb.publish(30);
    try testing.expect(mb.indicesArePermutation());
    // consume は最新
    try testing.expectEqual(@as(u32, 30), mb.acquire().*);
    // publish 無しなら現 view 維持
    try testing.expectEqual(@as(u32, 30), mb.acquire().*);
    try testing.expect(mb.indicesArePermutation());
}

test "dyn(a): 最小パッチ publish→render 非無音・finite・有界、実行中の add でも維持" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const vco = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const vca = try g.add(.vca, .{ .gain = 0.5 });
    const out = try g.add(.output, .{ .soft_clip = false, .pan = 0.0 });
    try g.connect(vco, 0, vca, 0);
    try g.connect(vca, 0, out, 0);
    g.setOutput(out);
    try g.publish();

    var buf: [512 * 2]f32 = undefined;
    g.processBlock(&buf, 512, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0);
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
    }

    // 実行中に無関係な第 2 VCO を追加（未接続）→ publish → 依然 finite/有界/非無音。
    _ = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    try g.publish();
    g.processBlock(&buf, 512, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0);
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
    }
}

test "dyn(c): 状態保持 — 無関係な add で既存 VCO の位相がリセットされない（サンプル一致）" {
    // ref: VCO->Output を 2 ブロック連続 render。
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

    // test: 同じ VCO->Output を 1 ブロック render 後、無関係な第 2 VCO を add+publish、その後 render。
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
    // 再配線: 無関係 VCO を追加（既存 v/o の接続・状態には無関係）。
    _ = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    try g.publish();
    g.processBlock(&g_b2, 128, 2);

    // block1 は当然一致。block2 も一致すれば「位相リセット無し・接続点で不連続なし」＝状態保持。
    try testing.expectEqualSlices(f32, &ref_b1, &g_b1);
    try testing.expectEqualSlices(f32, &ref_b2, &g_b2);
}

test "dyn(c2): DelayFx tail — 入力を切っても直後の tail が連続（状態保持）" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const vco = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 220 });
    const dly = try g.add(.delay, .{ .delay_ms = 20.0, .feedback = 0.7, .wet = 0.8 });
    const out = try g.add(.output, .{ .soft_clip = false, .pan = 0.0 });
    try g.connect(vco, 0, dly, 0);
    try g.connect(dly, 0, out, 0);
    g.setOutput(out);
    try g.publish();

    var buf: [4800 * 2]f32 = undefined;
    g.processBlock(&buf, 4800, 2); // delay line を満たす

    // vco→delay を切断（delay 入力 0）→ publish。tail（feedback）が残るので直後も非無音。
    g.disconnect(dly, 0);
    try g.publish();
    var tail: [480 * 2]f32 = undefined;
    g.processBlock(&tail, 480, 2);
    try testing.expect(rmsEven(&tail, 2) > 0.0); // tail が途切れない
    for (tail) |s| try testing.expect(std.math.isFinite(s));
}

test "dyn(b): 決定的 — 同一操作列 2 回で出力・最終 GraphView 一致" {
    const build = struct {
        fn go(alloc: std.mem.Allocator, out_buf: []f32) !GraphView {
            var g = try DynGraph.create(alloc, 48000);
            defer g.destroy();
            const v1 = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 220 });
            const m = try g.add(.mixer, .{ .gain = 0.4 });
            const o = try g.add(.output, .{ .soft_clip = false });
            try g.connect(v1, 0, m, 0);
            try g.connect(m, 0, o, 0);
            g.setOutput(o);
            try g.publish();
            var tmp: [256 * 2]f32 = undefined;
            g.processBlock(&tmp, 256, 2);
            // 追加接続
            const v2 = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 330 });
            try g.connect(v2, 0, m, 1);
            try g.publish();
            g.processBlock(out_buf, 256, 2);
            return g.currentView();
        }
    };
    var a: [256 * 2]f32 = undefined;
    var b: [256 * 2]f32 = undefined;
    const va = try build.go(testing.allocator, &a);
    const vb = try build.go(testing.allocator, &b);
    try testing.expectEqualSlices(f32, &a, &b);
    // 最終 GraphView（gen 除く）一致
    try testing.expectEqual(va.node_count, vb.node_count);
    try testing.expectEqual(va.output, vb.output);
    try testing.expectEqualSlices(u16, va.order[0..va.node_count], vb.order[0..vb.node_count]);
    try testing.expectEqualSlices([MAX_IN]i32, &va.in_src, &vb.in_src);
    try testing.expectEqualSlices([MAX_IN]bool, &va.in_delayed, &vb.in_delayed);
}

test "dyn(b2): 長い操作列（connect/disconnect/remove/reuse 込み）を 2 回適用して決定的" {
    // UI ライブ再配線を模した操作列: 構築→render→接続追加→render→切断→render→削除→publish→render→
    // grace 後に再 add→render。固定 seed（モジュール既定）で 2 グラフに同一適用し出力・最終 View が一致。
    const run = struct {
        fn go(alloc: std.mem.Allocator, out_buf: []f32) !GraphView {
            var g = try DynGraph.create(alloc, 48000);
            defer g.destroy();
            const v = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
            const f = try g.add(.vcf, .{ .cutoff = 900, .resonance = 2.0, .mode = .lowpass });
            const o = try g.add(.output, .{ .soft_clip = true });
            try g.connect(v, 0, f, 0);
            try g.connect(f, 0, o, 0);
            g.setOutput(o);
            try g.publish();
            var tmp: [128 * 2]f32 = undefined;
            g.processBlock(&tmp, 128, 2);
            // LFO を足して cutoff を変調
            const lfo = try g.add(.lfo, .{ .rate_hz = 1.0 });
            try g.connect(lfo, 0, f, 1);
            try g.publish();
            g.processBlock(&tmp, 128, 2);
            // 切断（LFO→cutoff を外す）
            g.disconnect(f, 1);
            try g.publish();
            g.processBlock(&tmp, 128, 2);
            // LFO を削除 → publish → render で grace 前進
            g.removeModule(lfo);
            try g.publish();
            g.processBlock(&tmp, 128, 2);
            // grace 済み slot を再利用（別モジュール）
            const mix = try g.add(.mixer, .{ .gain = 0.5 });
            try g.connect(v, 0, mix, 0);
            try g.publish();
            g.processBlock(out_buf, 128, 2);
            return g.currentView();
        }
    };
    var a: [128 * 2]f32 = undefined;
    var b: [128 * 2]f32 = undefined;
    const va = try run.go(testing.allocator, &a);
    const vb = try run.go(testing.allocator, &b);
    try testing.expectEqualSlices(f32, &a, &b);
    try testing.expectEqual(va.node_count, vb.node_count);
    try testing.expectEqual(va.output, vb.output);
    try testing.expectEqualSlices(u16, va.order[0..va.node_count], vb.order[0..vb.node_count]);
    try testing.expectEqualSlices([MAX_IN]i32, &va.in_src, &vb.in_src);
    try testing.expectEqualSlices([MAX_IN]bool, &va.in_delayed, &vb.in_delayed);
}

test "dyn(f): 単一接続 / 種別一致 / サイクル遅延 / エラー区別" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v1 = try g.add(.vco, .{});
    const v2 = try g.add(.vco, .{});
    const m = try g.add(.mixer, .{});
    const eg = try g.add(.env_gen, .{});
    // 単一接続: 同じ入力へ 2 本目はエラー
    try g.connect(v1, 0, m, 0);
    try testing.expectError(Error.InputAlreadyConnected, g.connect(v2, 0, m, 0));
    try g.connect(v2, 0, m, 1); // 別ポートは OK
    // 種別不一致: audio(out) -> gate(in) は拒否
    try testing.expectError(Error.PortKindMismatch, g.connect(v1, 0, eg, 0));

    // サイクル: mixer 出力を自分の in1 へ（self-loop）→ 遅延辺。
    const m2 = try g.add(.mixer, .{ .gain = 0.5 });
    try g.connect(v1, 0, m2, 0);
    try g.connect(m2, 0, m2, 1);
    g.setOutput(m2);
    try g.publish();
    try testing.expect(g.isDelayed(m2, 1));
    var buf: [256 * 2]f32 = undefined;
    g.processBlock(&buf, 256, 2);
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
    }
}

test "dyn(f2a): pool 枯渇は PoolFull（handle 空間に余裕があっても）" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    // output pool cap=2。使い切ると 3 本目は PoolFull（handle はまだ大量に空いている）。
    _ = try g.add(.output, .{});
    _ = try g.add(.output, .{});
    try testing.expectError(Error.PoolFull, g.add(.output, .{}));
    try testing.expect(g.activeCount() < MAX_MODULES);
}

test "dyn(f2b): handle 空間枯渇は TooManyModules（pool に余裕があっても）" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    // 総容量が MAX_MODULES を超える kind 群（vco12+vca12+env_gen12+vcf8+mixer8=52 >= 48）で
    // handle 空間ちょうど MAX_MODULES を埋める。各 kind は pool を使い切らない配分にする。
    const plan = [_]struct { k: ModuleKind, n: usize }{
        .{ .k = .vco, .n = 12 },
        .{ .k = .vca, .n = 12 },
        .{ .k = .env_gen, .n = 12 },
        .{ .k = .vcf, .n = 8 },
        .{ .k = .mixer, .n = 4 }, // 12+12+12+8+4 = 48 = MAX_MODULES
    };
    inline for (plan) |p| {
        var i: usize = 0;
        while (i < p.n) : (i += 1) _ = try g.add(p.k, .{});
    }
    try testing.expectEqual(@as(usize, MAX_MODULES), g.activeCount());
    // handle 空間が満杯 → pool にまだ余裕がある mixer(cap=8, 4 使用) でも TooManyModules。
    try testing.expectError(Error.TooManyModules, g.add(.mixer, .{}));
}

test "dyn(d): RT ゼロアロケーション — processBlock/publish が self.allocator を触らない（FailingAllocator）" {
    // create は通常 allocator で確保。以後 g.allocator を fail_index=0 の FailingAllocator に差し替え、
    // processBlock（RT 経路）と publish（非 RT だが per-call alloc 不在）を回す。もし self.allocator 経由で
    // alloc すれば即 OutOfMemory。destroy 前に通常 allocator へ戻す。
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    const f = try g.add(.vcf, .{ .cutoff = 800, .resonance = 4.0, .mode = .lowpass });
    const o = try g.add(.output, .{ .soft_clip = true });
    try g.connect(v, 0, f, 0);
    try g.connect(f, 0, o, 0);
    g.setOutput(o);
    try g.publish();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    g.allocator = failing.allocator();
    const chunk: u32 = 4096;
    var buf: [chunk * 2]f32 = undefined;
    var rendered: u64 = 0;
    const target: u64 = 96_000; // ~2s @48k（failing 下で回す）
    while (rendered < target) : (rendered += chunk) {
        g.processBlock(&buf, chunk, 2); // alloc すれば FailingAllocator が捕える
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001);
        }
    }
    // publish も failing 下で per-call alloc しないことを確認（scratch は stack）。
    _ = try g.add(.lfo, .{});
    try g.publish();
    g.processBlock(&buf, chunk, 2);
    // FailingAllocator が 1 度も呼ばれていない（= alloc 発生ゼロ）を確認。
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);

    g.allocator = testing.allocator; // destroy 用に戻す
}

test "dyn(i): poolFreeCount/freeHandleCount — add 前の空き数が add の実確保可能数と一致する（reclaim 込み）" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    try testing.expectEqual(poolCap(.output), g.poolFreeCount(.output));
    try testing.expectEqual(@as(usize, MAX_MODULES), g.freeHandleCount());

    _ = try g.add(.output, .{});
    try testing.expectEqual(poolCap(.output) - 1, g.poolFreeCount(.output));
    try testing.expectEqual(@as(usize, MAX_MODULES - 1), g.freeHandleCount());

    // pool 枯渇時は 0（TooManyModules/PoolFull と整合）。
    const o2 = try g.add(.output, .{}); // cap=2
    try testing.expectEqual(@as(usize, 0), g.poolFreeCount(.output));

    // remove 直後（publish/consume 前）は grace 未達 = まだ「使用中」扱い（reclaim されない）。
    g.removeModule(o2);
    try testing.expectEqual(@as(usize, 0), g.poolFreeCount(.output));

    // publish + processBlock で consumed_gen が retire_gen に追いつく → reclaim 相当で空きが戻る。
    try g.publish();
    var buf: [64 * 2]f32 = undefined;
    g.processBlock(&buf, 64, 2);
    try testing.expectEqual(@as(usize, 1), g.poolFreeCount(.output));
}

test "dyn(h3): RCU grace — remove 後 grace 未達の間は同 handle を再利用しない" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    var buf: [64 * 2]f32 = undefined;
    g.processBlock(&buf, 64, 2); // consumed_gen=1（v はまだ view gen1 に居る）

    // v を削除。retire_gen = gen+1（= 2、次 publish の view から消える）。
    g.removeModule(v);
    // grace 未達（consumed_gen=1 < retire_gen=2）で add → v を再利用してはいけない（別 handle）。
    const h_other = try g.add(.vco, .{ .osc = .{ .waveform = .square }, .base_hz = 220 });
    try testing.expect(h_other != v);
    g.removeModule(h_other);
}

test "dyn(h4): RCU grace — grace 成立後は同 handle を再利用し、signal port 範囲がクリアされ残留が漏れない" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    var buf: [256 * 2]f32 = undefined;
    g.processBlock(&buf, 256, 2); // v の出力ポートに sine の非ゼロ値が残る（sig_a/sig_b 両方）

    // v の port 範囲が実際に非ゼロ（＝この後の clear が効いているか検証できる状態）。
    const base: usize = @as(usize, v) * MAX_OUT;
    var pre_nonzero = false;
    for (g.sig_a[base..][0..MAX_OUT]) |x| {
        if (x != 0) pre_nonzero = true;
    }
    for (g.sig_b[base..][0..MAX_OUT]) |x| {
        if (x != 0) pre_nonzero = true;
    }
    try testing.expect(pre_nonzero);

    // v を削除 → publish（gen 前進、view から消える）→ processBlock で consumed_gen を retire_gen 以上へ。
    g.removeModule(v);
    try g.publish();
    g.processBlock(&buf, 256, 2); // consumed_gen が retire_gen 到達 → v が reclaim 可能

    // grace 成立後の add は最小の空き handle（= v）を確定的に再利用する。
    const reuse = try g.add(.vca, .{ .gain = 1.0 });
    try testing.expectEqual(v, reuse);
    // reuse 直後（process 前）に v の旧 port 範囲がクリアされている（残留が新モジュールへ漏れない）。
    for (g.sig_a[base..][0..MAX_OUT]) |x| try testing.expectEqual(@as(f32, 0), x);
    for (g.sig_b[base..][0..MAX_OUT]) |x| try testing.expectEqual(@as(f32, 0), x);

    try g.publish();
    g.processBlock(&buf, 256, 2);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}

// ---- TASK-40.8 D: per-port tap（RT 性質。offline 単スレッド決定論）----

/// slot0 に 1 ポートだけ載せた TapConfig を作る（テスト用ヘルパー）。
fn tapCfg(seq: u32, port: i32) graph_core.TapConfig {
    var c = graph_core.TapConfig{ .seq = seq };
    c.ports[0] = port;
    return c;
}

test "dyn(tap-a): tap 有効/無効で audio 出力が bit 一致（tap は非侵襲）" {
    const build = struct {
        fn go(alloc: std.mem.Allocator, out_buf: []f32, enable_tap: bool) !void {
            var g = try DynGraph.create(alloc, 48000);
            defer g.destroy();
            const v = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
            const o = try g.add(.output, .{ .soft_clip = true });
            try g.connect(v, 0, o, 0);
            g.setOutput(o);
            try g.publish();
            if (enable_tap) g.publishTapConfig(tapCfg(1, @intCast(@as(u32, v) * MAX_OUT)));
            g.processBlock(out_buf, @intCast(out_buf.len / 2), 2);
        }
    };
    var a: [512 * 2]f32 = undefined;
    var b: [512 * 2]f32 = undefined;
    try build.go(testing.allocator, &a, false);
    try build.go(testing.allocator, &b, true);
    try testing.expectEqualSlices(f32, &a, &b); // tap は buf に非侵襲
}

test "dyn(tap-b): tap リングは決定的・decimation rate 通り・発振源で非定数" {
    const F: u32 = 512;
    const build = struct {
        fn go(alloc: std.mem.Allocator, ring_out: []f32) !u32 {
            var g = try DynGraph.create(alloc, 48000);
            defer g.destroy();
            const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
            const o = try g.add(.output, .{ .soft_clip = false });
            try g.connect(v, 0, o, 0);
            g.setOutput(o);
            try g.publish();
            g.publishTapConfig(tapCfg(1, @intCast(@as(u32, v) * MAX_OUT)));
            var buf: [F * 2]f32 = undefined;
            g.processBlock(&buf, F, 2);
            _ = g.tapWindow(0, ring_out);
            return g.tapWpos(0);
        }
    };
    var r1: [graph_core.TAP_RING]f32 = undefined;
    var r2: [graph_core.TAP_RING]f32 = undefined;
    const w1 = try build.go(testing.allocator, &r1);
    const w2 = try build.go(testing.allocator, &r2);
    try testing.expectEqual(@as(u32, F / graph_core.TAP_DECIM), w1); // 間引きレート通り（wrap しない範囲）
    try testing.expectEqual(w1, w2);
    const n = @min(@as(usize, w1), graph_core.TAP_RING);
    try testing.expectEqualSlices(f32, r1[0..n], r2[0..n]); // 決定的
    var mn: f32 = 0;
    var mx: f32 = 0;
    for (r1[0..n]) |x| {
        mn = @min(mn, x);
        mx = @max(mx, x);
    }
    try testing.expect(mn < 0 and mx > 0); // 発振している（定数でない）
}

test "dyn(tap-c): tap 有効の processBlock + config publish がゼロアロケーション" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    const o = try g.add(.output, .{ .soft_clip = true });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    const port: i32 = @intCast(@as(u32, v) * MAX_OUT);
    g.publishTapConfig(tapCfg(1, port));

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    g.allocator = failing.allocator();
    const chunk: u32 = 4096;
    var buf: [chunk * 2]f32 = undefined;
    var rendered: u64 = 0;
    var seq: u32 = 2;
    while (rendered < 96_000) : (rendered += chunk) {
        g.publishTapConfig(tapCfg(seq, port)); // publish も alloc しない
        seq += 1;
        g.processBlock(&buf, chunk, 2);
        for (buf) |s| try testing.expect(std.math.isFinite(s));
    }
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    g.allocator = testing.allocator;
}

test "dyn(tap-d): config 差し替え・remove/reuse で finite・slot リセット（旧 port 混入なし）" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v1 = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const v2 = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 110 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v1, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    var buf: [512 * 2]f32 = undefined;

    // slot0 = v1 → 512 frame で 128 サンプル書かれる。
    g.publishTapConfig(tapCfg(1, @intCast(@as(u32, v1) * MAX_OUT)));
    g.processBlock(&buf, 512, 2);
    try testing.expectEqual(@as(u32, 512 / graph_core.TAP_DECIM), g.tapWpos(0));
    try testing.expectEqual(@as(u32, 1), g.tapAppliedSeq());

    // slot0 を v2 へ差し替え → 次 block で wpos が 0 リセット後の新規カウントのみ（128 から増え続けない）。
    g.publishTapConfig(tapCfg(2, @intCast(@as(u32, v2) * MAX_OUT)));
    g.processBlock(&buf, 256, 2);
    try testing.expectEqual(@as(u32, 256 / graph_core.TAP_DECIM), g.tapWpos(0)); // リセット済み
    try testing.expectEqual(@as(u32, 2), g.tapAppliedSeq());

    // remove + publish + reuse を挟んでも finite・クラッシュ無し。
    g.removeModule(v1);
    try g.publish();
    g.processBlock(&buf, 256, 2);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}

test "dyn(tap-e): gate は peak 間引きで 1 サンプル幅パルスを取りこぼさず捕捉する" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const clk = try g.add(.clock, .{ .bpm = 240, .ppqn = 8 }); // 高頻度 tick（1 サンプル幅トリガ）
    const o = try g.add(.output, .{});
    g.setOutput(o);
    try g.publish(); // 未接続でも全 active ノードは order に入り毎サンプル評価される（clock.out0 が書かれる）
    // slot0 = clock.out0、coarse decim + peak。plain 間引きなら 1/256 でしか当たらないパルスも max で拾う。
    var cfg = graph_core.TapConfig{ .seq = 1 };
    cfg.ports[0] = @intCast(@as(u32, clk) * MAX_OUT);
    cfg.decim[0] = 256;
    cfg.peak[0] = true;
    g.publishTapConfig(cfg);
    var buf: [4096 * 2]f32 = undefined;
    var i: usize = 0;
    while (i < 12) : (i += 1) g.processBlock(&buf, 4096, 2); // ~1s（多数の tick を含む）
    var win: [graph_core.TAP_RING]f32 = undefined;
    const n = g.tapWindow(0, &win);
    var mx: f32 = 0;
    for (win[0..n]) |v| mx = @max(mx, v);
    try testing.expect(mx > 0.5); // gate パルスが窓内 max として捕捉されている
}

test "dyn(tap-cacheline): GUI 書き領域(tap_mailbox) と RT 書き領域(tap) が別キャッシュライン" {
    const cl = std.atomic.cache_line;
    const mb = @offsetOf(DynGraph, "tap_mailbox");
    const tp = @offsetOf(DynGraph, "tap");
    try testing.expect(mb % cl == 0);
    try testing.expect(tp % cl == 0);
    const diff = if (tp > mb) tp - mb else mb - tp;
    try testing.expect(diff >= cl); // 別ライン（false sharing の GUI×RT ペアを分離）
}
