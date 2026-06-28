//! libs/modular: グラフエンジン本体（signal のみに依存。modules は import しない＝generic）。
//!
//! - 全要素を起動時に1回固定確保（init / finalize）。process 経路に alloc/lock/IO なし（RT 安全）。
//! - per-sample 処理（毎サンプル全モジュールを topo 順に評価）。clock/trigger をサンプル精度に保つ。
//! - 入力ポートは単一接続のみ。合算は Mixer 明示（AC#2）。
//! - サイクル辺は build 時に delayed として明示化し「前サンプル値」を読む（初期 0・全 process 完了後に確定。AC#5）。
//! - 内部 mono。Output ノードの L/R を master 出力として interleaved stereo へ書く（AC#7）。

const std = @import("std");
const signal = @import("signal.zig");

const PortKind = signal.PortKind;
const Io = signal.Io;

/// グラフの固定確保サイズ。
pub const Caps = struct {
    /// モジュール数の上限。
    max_modules: usize,
    /// 出力ポート総数の上限（= signal バッファ長）。
    max_ports: usize,
};

const Color = enum(u8) { unvisited, visiting, done };

const Node = struct {
    vtable: *const signal.VTable,
    ctx: *anyopaque,
    n_in: u8,
    n_out: u8,
    in_kinds: [signal.MAX_IN]PortKind = undefined,
    out_kinds: [signal.MAX_OUT]PortKind = undefined,
    /// この node の出力ポートが signal バッファで占める先頭 index。
    out_base: u32,
    /// 各入力ポートの接続元グローバル出力ポート id（未接続 = -1）。
    in_src: [signal.MAX_IN]i32 = [_]i32{-1} ** signal.MAX_IN,
    /// 各入力ポートがサイクル遅延辺か（前サンプル値を読む）。
    in_delayed: [signal.MAX_IN]bool = [_]bool{false} ** signal.MAX_IN,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    sample_rate: f32,

    nodes: []Node,
    node_count: usize = 0,

    /// グローバル出力ポート id -> 所有 node index（topo の依存解決に使う）。
    port_owner: []u32,
    /// finalize で決まる処理順（依存が先、長さ = node_count）。
    order: []usize,

    // signal バッファ ping-pong（cur = 今サンプル, prev = 前サンプル）。出力ポート単位。
    sig_a: []f32,
    sig_b: []f32,
    cur: []f32,
    prev: []f32,
    port_count: u32 = 0,

    output_node: ?usize = null,
    out_l: f32 = 0,
    out_r: f32 = 0,
    finalized: bool = false,

    pub const Error = error{
        TooManyModules,
        TooManyPorts,
        TooManyInputs,
        TooManyOutputs,
        InputAlreadyConnected,
        PortKindMismatch,
        BadPortIndex,
        BadNodeIndex,
    } || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, sample_rate: f32, caps: Caps) Error!Graph {
        const nodes = try allocator.alloc(Node, caps.max_modules);
        errdefer allocator.free(nodes);
        const port_owner = try allocator.alloc(u32, caps.max_ports);
        errdefer allocator.free(port_owner);
        const order = try allocator.alloc(usize, caps.max_modules);
        errdefer allocator.free(order);
        const sig_a = try allocator.alloc(f32, caps.max_ports);
        errdefer allocator.free(sig_a);
        const sig_b = try allocator.alloc(f32, caps.max_ports);
        errdefer allocator.free(sig_b);
        @memset(sig_a, 0);
        @memset(sig_b, 0);
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .nodes = nodes,
            .port_owner = port_owner,
            .order = order,
            .sig_a = sig_a,
            .sig_b = sig_b,
            .cur = sig_a,
            .prev = sig_b,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.port_owner);
        self.allocator.free(self.order);
        self.allocator.free(self.sig_a);
        self.allocator.free(self.sig_b);
        self.* = undefined;
    }

    /// モジュールを追加し node index を返す。出力ポートを signal バッファへ割り当てる。
    pub fn addModule(self: *Graph, spec: signal.NodeSpec) Error!usize {
        if (self.node_count >= self.nodes.len) return Error.TooManyModules;
        if (spec.in_kinds.len > signal.MAX_IN) return Error.TooManyInputs;
        if (spec.out_kinds.len > signal.MAX_OUT) return Error.TooManyOutputs;
        const n_out: u32 = @intCast(spec.out_kinds.len);
        if (self.port_count + n_out > self.port_owner.len) return Error.TooManyPorts;

        const idx = self.node_count;
        var node = Node{
            .vtable = spec.vtable,
            .ctx = spec.ctx,
            .n_in = @intCast(spec.in_kinds.len),
            .n_out = @intCast(spec.out_kinds.len),
            .out_base = self.port_count,
        };
        for (spec.in_kinds, 0..) |k, i| node.in_kinds[i] = k;
        for (spec.out_kinds, 0..) |k, j| {
            node.out_kinds[j] = k;
            self.port_owner[self.port_count + @as(u32, @intCast(j))] = @intCast(idx);
        }
        self.port_count += n_out;
        self.nodes[idx] = node;
        self.node_count += 1;
        self.finalized = false;
        return idx;
    }

    /// src_node の出力 src_out を dst_node の入力 dst_in に接続する。
    /// 入力ポートは単一接続のみ（既接続はエラー）。種別は一致必須。
    pub fn connect(self: *Graph, src_node: usize, src_out: usize, dst_node: usize, dst_in: usize) Error!void {
        if (src_node >= self.node_count or dst_node >= self.node_count) return Error.BadNodeIndex;
        const s = &self.nodes[src_node];
        const d = &self.nodes[dst_node];
        if (src_out >= s.n_out or dst_in >= d.n_in) return Error.BadPortIndex;
        if (s.out_kinds[src_out] != d.in_kinds[dst_in]) return Error.PortKindMismatch;
        if (d.in_src[dst_in] != -1) return Error.InputAlreadyConnected;
        d.in_src[dst_in] = @intCast(s.out_base + @as(u32, @intCast(src_out)));
        self.finalized = false;
    }

    /// master 出力ノードを指定する（その out0/out1 を L/R として読む）。
    pub fn setOutputNode(self: *Graph, idx: usize) void {
        self.output_node = idx;
    }

    /// 処理順（topo）とサイクル遅延辺を確定する。process 前に1回呼ぶ。
    pub fn finalize(self: *Graph) Error!void {
        const colors = try self.allocator.alloc(Color, self.node_count);
        defer self.allocator.free(colors);
        @memset(colors, .unvisited);
        // 遅延辺フラグはやり直しに備えクリア（再 finalize 対応）。
        for (self.nodes[0..self.node_count]) |*n| n.in_delayed = [_]bool{false} ** signal.MAX_IN;

        var order_len: usize = 0;
        // ルートを slot index 昇順に DFS（接続順非依存の安定順序）。
        for (0..self.node_count) |u| {
            if (colors[u] == .unvisited) self.dfs(u, colors, &order_len);
        }
        std.debug.assert(order_len == self.node_count);

        // master 出力ノードの妥当性を非 RT 側でここで検証（RT process では panic させない）。
        if (self.output_node) |on| {
            if (on >= self.node_count or self.nodes[on].n_out < 1) return Error.BadNodeIndex;
        }

        // signal バッファを初期化（遅延辺の初期値 0）。
        @memset(self.sig_a, 0);
        @memset(self.sig_b, 0);
        self.cur = self.sig_a;
        self.prev = self.sig_b;
        self.finalized = true;
    }

    /// DFS（依存を先に積む）。visiting 中の依存先＝back edge を遅延辺として印付ける。
    fn dfs(self: *Graph, u: usize, colors: []Color, order_len: *usize) void {
        colors[u] = .visiting;
        const node = &self.nodes[u];
        var i: usize = 0;
        while (i < node.n_in) : (i += 1) {
            const s = node.in_src[i];
            if (s < 0) continue;
            const v: usize = self.port_owner[@intCast(s)];
            if (v == u) {
                node.in_delayed[i] = true; // self-loop は遅延
                continue;
            }
            switch (colors[v]) {
                .unvisited => self.dfs(v, colors, order_len),
                .visiting => node.in_delayed[i] = true, // back edge → 遅延
                .done => {},
            }
        }
        colors[u] = .done;
        self.order[order_len.*] = u;
        order_len.* += 1;
    }

    /// 1 サンプル評価。topo 順に各モジュールを process し、master 出力を捕捉して ping-pong を入れ替える。
    fn processSample(self: *Graph) void {
        var in_vals: [signal.MAX_IN]f32 = undefined;
        var in_conn: [signal.MAX_IN]bool = undefined;
        for (self.order[0..self.node_count]) |ni| {
            const node = &self.nodes[ni];
            var i: usize = 0;
            while (i < node.n_in) : (i += 1) {
                const s = node.in_src[i];
                if (s < 0) {
                    in_vals[i] = 0;
                    in_conn[i] = false;
                } else {
                    const sp: usize = @intCast(s);
                    in_conn[i] = true;
                    in_vals[i] = if (node.in_delayed[i]) self.prev[sp] else self.cur[sp];
                }
            }
            var io = Io{
                .inputs = in_vals[0..node.n_in],
                .connected = in_conn[0..node.n_in],
                .outputs = self.cur[node.out_base..][0..node.n_out],
                .sample_rate = self.sample_rate,
            };
            node.vtable.process(node.ctx, &io);
        }

        // master 出力を swap 前に捕捉（swap 後は prev 側に移るため）。
        if (self.output_node) |on| {
            const ob = self.nodes[on].out_base;
            self.out_l = self.cur[ob];
            self.out_r = if (self.nodes[on].n_out >= 2) self.cur[ob + 1] else self.cur[ob];
        }

        // ping-pong 入替: 次サンプルの prev = 今サンプルの cur（= 遅延辺が読む値）。
        const tmp = self.cur;
        self.cur = self.prev;
        self.prev = tmp;
    }

    /// ブロック先頭で全モジュールの係数を更新（tan 等の重い計算はここ＝ブロックレート）。
    fn updateAllParams(self: *Graph) void {
        for (self.nodes[0..self.node_count]) |*node| {
            node.vtable.updateParams(node.ctx, self.sample_rate);
        }
    }

    /// interleaved 出力へ `frames` サンプル書き込む。渡された frames/channels を正として処理する（AC#9）。
    /// channels==1 は (L+R)/2、>=2 は L/R を書き残りを 0。
    /// RT callback から呼べるよう panic/OOB を出さない: 未 finalize / channels==0 は no-op、
    /// frames は buf 容量に clamp する（不正は finalize で弾く前提＝非 RT 側で検証済み）。
    pub fn processBlock(self: *Graph, buf: []f32, frames: u32, channels: u32) void {
        if (!self.finalized or channels == 0) {
            @memset(buf, 0); // RT で stale バッファを鳴らさない
            return;
        }
        const ch: usize = channels;
        const cap: usize = buf.len / ch;
        const n: usize = @min(@as(usize, frames), cap);
        self.updateAllParams();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.processSample();
            if (ch == 1) {
                buf[i] = (self.out_l + self.out_r) * 0.5;
            } else {
                const base = i * ch;
                buf[base] = self.out_l;
                buf[base + 1] = self.out_r;
                var c: usize = 2;
                while (c < ch) : (c += 1) buf[base + c] = 0;
            }
        }
    }

    // --- テスト用イントロスペクション ---
    pub fn isDelayed(self: *const Graph, node: usize, in_port: usize) bool {
        return self.nodes[node].in_delayed[in_port];
    }
    pub fn orderSlice(self: *const Graph) []const usize {
        return self.order[0..self.node_count];
    }
};
