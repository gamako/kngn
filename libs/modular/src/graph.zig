//! libs/modular: the graph engine (depends only on signal; does not import modules = generic).
//!
//! - Fixed allocation of every element once at startup (init / finalize). No alloc/lock/IO on the process path (RT-safe).
//! - Per-sample processing (every sample evaluates all modules in topo order). Keeps clock/trigger sample-accurate.
//! - Input ports accept a single connection only. Summing is done by an explicit Mixer.
//! - Cycle edges are marked delayed at build time and read the previous-sample value (initially 0; settled after all process calls for the sample finish).
//! - Internally mono. The Output node's L/R are written as the master output into interleaved stereo.

const std = @import("std");
const signal = @import("signal.zig");
const graph_core = @import("graph_core.zig");

const PortKind = signal.PortKind;
const ProcNode = graph_core.ProcNode;

/// Fixed-allocation size for the graph.
pub const Caps = struct {
    /// Upper bound on the number of modules.
    max_modules: usize,
    /// Upper bound on the total number of output ports (= signal buffer length).
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
    /// Start index of this node's output ports in the signal buffer.
    out_base: u32,
    /// Global output-port id feeding each input port (unconnected = -1).
    in_src: [signal.MAX_IN]i32 = [_]i32{-1} ** signal.MAX_IN,
    /// Whether each input port is a cycle-delay edge (reads the previous sample).
    in_delayed: [signal.MAX_IN]bool = [_]bool{false} ** signal.MAX_IN,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    sample_rate: f32,

    nodes: []Node,
    node_count: usize = 0,

    /// Global output-port id -> owning node index (used for topo dependency resolution).
    port_owner: []u32,
    /// Processing order fixed by finalize (dependencies first; length = node_count).
    order: []usize,
    /// ProcNode sequence baked in order by finalize (shared form driven by graph_core; equivalent to baking a View).
    order_nodes: []ProcNode,
    /// DFS scratch for topo sort (allocated once in init and reused in finalize = zero per-finalize alloc).
    colors: []Color,

    // Signal-buffer ping-pong (cur = current sample, prev = previous sample). Per output port.
    sig_a: []f32,
    sig_b: []f32,
    cur: []f32,
    prev: []f32,
    port_count: u32 = 0,

    output_node: ?usize = null,
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
        const order_nodes = try allocator.alloc(ProcNode, caps.max_modules);
        errdefer allocator.free(order_nodes);
        const colors = try allocator.alloc(Color, caps.max_modules);
        errdefer allocator.free(colors);
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
            .order_nodes = order_nodes,
            .colors = colors,
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
        self.allocator.free(self.order_nodes);
        self.allocator.free(self.colors);
        self.allocator.free(self.sig_a);
        self.allocator.free(self.sig_b);
        self.* = undefined;
    }

    /// Add a module and return its node index. Allocates its output ports in the signal buffer.
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

    /// Connect output src_out of src_node to input dst_in of dst_node.
    /// Input ports accept a single connection only (already connected is an error). Port kinds must match.
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

    /// Set the master output node (its out0/out1 are read as L/R).
    pub fn setOutputNode(self: *Graph, idx: usize) void {
        self.output_node = idx;
    }

    /// Fix the processing order (topo) and cycle-delay edges. Call once before process.
    /// Does not allocate per finalize (reuses the colors field allocated in init = RT zero-allocation policy).
    pub fn finalize(self: *Graph) Error!void {
        const colors = self.colors[0..self.node_count];
        @memset(colors, .unvisited);
        // Clear delay-edge flags so a re-finalize starts clean.
        for (self.nodes[0..self.node_count]) |*n| n.in_delayed = [_]bool{false} ** signal.MAX_IN;

        var order_len: usize = 0;
        // DFS roots in ascending slot-index order (stable order independent of connect order).
        for (0..self.node_count) |u| {
            if (colors[u] == .unvisited) self.dfs(u, colors, &order_len);
        }
        std.debug.assert(order_len == self.node_count);

        // Validate the master output node here on the non-RT side (do not panic in RT process).
        if (self.output_node) |on| {
            if (on >= self.node_count or self.nodes[on].n_out < 1) return Error.BadNodeIndex;
        }

        // Bake ProcNodes in order (shared form driven by graph_core; in_delayed is already fixed by dfs).
        for (self.order[0..self.node_count], 0..) |ni, k| {
            const nd = &self.nodes[ni];
            self.order_nodes[k] = .{
                .vtable = nd.vtable,
                .ctx = nd.ctx,
                .n_in = nd.n_in,
                .n_out = nd.n_out,
                .out_base = nd.out_base,
                .in_src = nd.in_src,
                .in_delayed = nd.in_delayed,
            };
        }

        // Initialise the signal buffers (delay edges start at 0).
        @memset(self.sig_a, 0);
        @memset(self.sig_b, 0);
        self.cur = self.sig_a;
        self.prev = self.sig_b;
        self.finalized = true;
    }

    /// DFS (push dependencies first). A dependency still visiting = a back edge, marked as a delay edge.
    fn dfs(self: *Graph, u: usize, colors: []Color, order_len: *usize) void {
        colors[u] = .visiting;
        const node = &self.nodes[u];
        var i: usize = 0;
        while (i < node.n_in) : (i += 1) {
            const s = node.in_src[i];
            if (s < 0) continue;
            const v: usize = self.port_owner[@intCast(s)];
            if (v == u) {
                node.in_delayed[i] = true; // A self-loop is a delay
                continue;
            }
            switch (colors[v]) {
                .unvisited => self.dfs(v, colors, order_len),
                .visiting => node.in_delayed[i] = true, // back edge -> delay
                .done => {},
            }
        }
        colors[u] = .done;
        self.order[order_len.*] = u;
        order_len.* += 1;
    }

    /// Write `frames` samples into the interleaved output. Treat the given frames/channels as authoritative.
    /// channels==1 writes (L+R)/2; >=2 writes L/R and zeros the rest.
    /// Callable from an RT callback with no panic/OOB: unfinalised / channels==0 is a no-op (zero-fill),
    /// and frames is clamped to the buf capacity (invalid state is rejected in finalize = verified on the non-RT side).
    /// Per-sample evaluation is delegated to graph_core (the shared static/dynamic kernel).
    /// The master output is resolved live from self.output_node every block (setOutputNode after finalize still takes effect = behaviour unchanged).
    pub fn processBlock(self: *Graph, buf: []f32, frames: u32, channels: u32) void {
        if (!self.finalized or channels == 0) {
            @memset(buf, 0); // Do not play a stale buffer on the RT path
            return;
        }
        const out_sel: ?graph_core.OutputSel = if (self.output_node) |on|
            .{ .out_base = self.nodes[on].out_base, .n_out = self.nodes[on].n_out }
        else
            null;
        graph_core.processBlock(
            self.order_nodes[0..self.node_count],
            out_sel,
            self.sample_rate,
            &self.cur,
            &self.prev,
            buf,
            frames,
            channels,
        );
    }

    // --- Test introspection ---
    pub fn isDelayed(self: *const Graph, node: usize, in_port: usize) bool {
        return self.nodes[node].in_delayed[in_port];
    }
    pub fn orderSlice(self: *const Graph) []const usize {
        return self.order[0..self.node_count];
    }
};
