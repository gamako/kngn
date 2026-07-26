//! libs/modular: dynamic graph engine + RT-safe live rewiring.
//!
//! Design: docs/modular.md. Five tenets (Zig-style memory design for performance):
//!   1. Topology / DSP-state separation: publish passes only a GraphView to the RT (connections, order, handles = a few KB).
//!      DSP state (DelayLine 256KB each, Reverb, phase, filter memory) stays in RT-owned pools and is never put on a publish.
//!   2. Per-type fixed pools: do not put every module in one union(enum) (largest member DelayFx≈256KB × [N] balloons);
//!      use per-type fixed array pools (many cheap modules / few DelayFx·ReverbFx). Arrays never move so ctx is stable and RT never allocates.
//!   3. POD View + handle refs: GraphView is a value type of fixed inline arrays with no pointers. RT resolves
//!      vtable/ctx/out_base/n_in/n_out from handles via the stable registry (instances).
//!   4. Zero allocation on the RT path: topo sort, cycle detection and View construction are all on the main side. processBlock
//!      holds no allocator; only stack scratch.
//!   5. Fixed port-id assignment: instance slot i permanently owns output port ids [i*MAX_OUT..). port_owner is
//!      derived as port_id/MAX_OUT. Port positions stay stable across rewiring, so delayed-edge previous samples are kept.
//!
//! RT-safe live rewiring:
//!   - publish is an SPSC triple-buffer (three slots). Even under consecutive publishes the producer never writes the consumer's read slot
//!     (the three indices are a permutation of {0,1,2}) → no torn read, latest-wins, non-blocking.
//!   - handle/pool-slot reuse is RCU-style grace: removeModule does not destroy RT-read fields; it marks retired + retire_gen.
//!     Reuse is forbidden until consumed_gen (gen of the view the RT latched) >= retire_gen (guarantees the old view has finished processing).
//!
//! Self-referential (instances.ctx points into pools), so **allocate on the heap and never move** (create/destroy).
//! signal/pool/view are inline fixed allocations; the render path holds no allocator at all.

const std = @import("std");
const signal = @import("signal.zig");
const graph_core = @import("graph_core.zig");
const modules = @import("modules.zig");

const PortKind = signal.PortKind;
const ProcNode = graph_core.ProcNode;
const MAX_IN = signal.MAX_IN;
const MAX_OUT = signal.MAX_OUT;

/// Basis for handle / instance / View width and port stride.
/// Overridable via `-Dmax-modules=N` (build_options.max_modules). Default 48.
pub const MAX_MODULES: usize = @import("build_options").max_modules;
/// Signal-buffer length (fixed port-id assignment slot*MAX_OUT).
pub const MAX_PORTS: usize = @as(usize, MAX_MODULES) * MAX_OUT;

pub const Handle = u16;

/// Module kinds (enumerates every type). KindType / poolCap / poolArray branch on this enum.
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
    slew,
    sample_hold,
    comparator,
    ring_mod,
    logic,
};

/// kind → concrete type.
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
        .slew => modules.Slew,
        .sample_hold => modules.SampleHold,
        .comparator => modules.Comparator,
        .ring_mod => modules.RingMod,
        .logic => modules.Logic,
    };
}

/// kind → pool capacity (many cheap modules / few delay·reverb. Total may exceed the handle space, but
/// the active count is capped by MAX_MODULES).
///
/// Scale the default caps proportionally by `MAX_MODULES/48`. At the default N=48,
/// `base * 48 / 48 == base` so values match exactly (bit-identical). Larger N also lifts the FX caps.
pub fn poolCap(comptime k: ModuleKind) usize {
    const base: usize = switch (k) {
        .vco, .vca, .env_gen => 12,
        // step_seq 4→8 (DrumMachine×2=4 + BassMachine=1 would exhaust cap 4. Small struct; Pools growth is tiny).
        .vcf, .mixer, .lfo, .step_seq => 8,
        .euclid, .perc_env, .random => 6,
        .clock, .clock_divider, .quantizer, .kick, .hat, .turing, .clap, .chord_pad, .saturator, .bitcrusher, .sidechain => 4,
        .output, .delay, .reverb, .vinyl, .wow_flutter => 2,
        .slew, .sample_hold, .comparator, .logic => 6,
        .ring_mod => 4,
    };
    // At default 48, scale=1. `@max(base, …)` is effectively base * N/48 because builds already reject N<48.
    return @max(base, base * MAX_MODULES / 48);
}

/// Per-type fixed pools (explicit fields; avoid comptime tuple generation for compile safety and readability). DSP state resides here (not on publish).
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
    slew: [poolCap(.slew)]modules.Slew,
    sample_hold: [poolCap(.sample_hold)]modules.SampleHold,
    comparator: [poolCap(.comparator)]modules.Comparator,
    ring_mod: [poolCap(.ring_mod)]modules.RingMod,
    logic: [poolCap(.logic)]modules.Logic,
};

/// Stable-registry fields the RT reads (immutable after init while the matching handle is active/retired).
const Instance = struct {
    vtable: *const signal.VTable = undefined,
    ctx: *anyopaque = undefined,
    n_in: u8 = 0,
    n_out: u8 = 0,
    /// Start index of output ports in the signal buffer (= handle * MAX_OUT).
    out_base: u32 = 0,
    in_kinds: [MAX_IN]PortKind = undefined,
    out_kinds: [MAX_OUT]PortKind = undefined,
};

/// Lifecycle metadata (main only; RT does not read — separated from Instance).
const SlotMeta = struct {
    active: bool = false,
    retired: bool = false,
    kind: ModuleKind = .vco,
    pool_idx: u16 = 0,
    /// Gen of the first view from which the handle disappears after retire (reusable once consumed_gen>=this).
    retire_gen: u64 = 0,
};

const Color = enum(u8) { unvisited, visiting, done };

/// POD graph description published to the RT (no pointers; index/handle refs only). Published by value copy.
pub const GraphView = struct {
    gen: u64 = 0,
    node_count: u16 = 0,
    /// Processing-order handle sequence (length = node_count).
    order: [MAX_MODULES]u16 = [_]u16{0} ** MAX_MODULES,
    /// Per-handle, per-input global source output-port id (unconnected = -1).
    in_src: [MAX_MODULES][MAX_IN]i32 = [_][MAX_IN]i32{[_]i32{-1} ** MAX_IN} ** MAX_MODULES,
    /// Per-handle, per-input cycle-delay-edge flags.
    in_delayed: [MAX_MODULES][MAX_IN]bool = [_][MAX_IN]bool{[_]bool{false} ** MAX_IN} ** MAX_MODULES,
    /// Master output handle (-1 = none).
    output: i32 = -1,

    pub fn empty() GraphView {
        return .{};
    }
};

// ============================================================================
// SPSC triple-buffer (three slots). producer=main / consumer=RT. Safe under consecutive publish; non-blocking; latest-wins.
// shared = index(low 2 bits) | FRESH_BIT. The three indices {write_idx, read_idx, shared&IDX} are always a permutation of {0,1,2},
// so the producer never writes the read slot → no torn read.
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

        /// producer(main): write the private write slot then swap with ready (never block).
        pub fn publish(self: *Self, value: T) void {
            self.bufs[self.write_idx] = value;
            const new: u8 = self.write_idx | FRESH;
            const old = self.shared.swap(new, .acq_rel);
            self.write_idx = old & IDX_MASK;
        }

        /// consumer(RT): if fresh, swap the read slot with ready and latch the latest; otherwise keep the current view.
        pub fn acquire(self: *Self) *const T {
            const s = self.shared.load(.acquire);
            if (s & FRESH != 0) {
                const old = self.shared.swap(self.read_idx, .acq_rel);
                self.read_idx = old & IDX_MASK;
            }
            return &self.bufs[self.read_idx];
        }

        /// Test helper: assert the three indices are a permutation of {0,1,2} (h1 invariant).
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
    TooManyModules, // Handle space (MAX_MODULES) exhausted
    PoolFull, // That kind's pool exhausted
    BadNodeIndex,
    BadPortIndex,
    InputAlreadyConnected,
    PortKindMismatch,
} || std.mem.Allocator.Error;

pub const DynGraph = struct {
    allocator: std.mem.Allocator, // Used only by create/destroy (the render path never touches it)
    sample_rate: f32,

    pools: Pools,
    instances: [MAX_MODULES]Instance,
    slots: [MAX_MODULES]SlotMeta,

    // staging (main edits). stage_in_src is indexed by handle.
    stage_in_src: [MAX_MODULES][MAX_IN]i32,
    stage_output: i32,

    // publish generation + gen the RT latched.
    gen: u64,
    consumed_gen: std.atomic.Value(u64),
    mailbox: Mailbox(GraphView),
    /// Main-side latest publish copy (test introspection; RT does not read).
    last_published: GraphView,

    // signal ping-pong (inline fixed allocation. cur/prev are slices into sig_a/sig_b that swap).
    sig_a: [MAX_PORTS]f32,
    sig_b: [MAX_PORTS]f32,
    cur: []f32,
    prev: []f32,

    // Per-port mini-oscilloscope tap.
    // cache_line isolation: put the GUI-write region (tap_mailbox) and the RT-write region (tap: applied_seq/wpos/ring) on separate lines.
    // The harmful false-sharing pair is "GUI write × RT write", so separating these two blocks is enough
    // (inter-slot wpos is written only by the single RT thread; GUI only reads, so co-residence is fine).
    tap_mailbox: Mailbox(graph_core.TapConfig) align(std.atomic.cache_line),
    tap: graph_core.TapState align(std.atomic.cache_line),

    // Reuse the ProcNode sequence + master out_sel without rebuilding while view.gen is unchanged (symmetric with
    // the static Graph baking once in finalize. Removes waste on the per-block RT path). RT-thread exclusive (read/write
    // only inside processBlock), so atomics / cache_line isolation do not apply (do not add atomic pairs shared with the GUI).
    proc_cache: [MAX_MODULES]ProcNode,
    cached_out_sel: ?graph_core.OutputSel,
    cache_gen: u64,
    cache_valid: bool,
    /// How many times the ProcNode sequence was actually rebuilt (observable used by tests to pin the "skip" performance property).
    /// Only the RT thread writes (+%= wrapping so a safety-build overflow trap = RT panic cannot fire); tests call
    /// processBlock on the same thread so they can read it directly.
    rebuild_count: u64,

    /// Heap-allocate and initialise (self-referential pointers forbid moving).
    pub fn create(allocator: std.mem.Allocator, sample_rate: f32) Error!*DynGraph {
        const self = try allocator.create(DynGraph);
        self.* = .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .pools = undefined, // Slots are written on activate; unused regions are never read
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
            .proc_cache = undefined, // Do not read [0..node_count] while cache_valid=false
            .cached_out_sel = null,
            .cache_gen = 0,
            .cache_valid = false,
            .rebuild_count = 0,
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
            .slew => &self.pools.slew,
            .sample_hold => &self.pools.sample_hold,
            .comparator => &self.pools.comparator,
            .ring_mod => &self.pools.ring_mod,
            .logic => &self.pools.logic,
        };
    }

    pub fn isActive(self: *const DynGraph, h: Handle) bool {
        return h < MAX_MODULES and self.slots[h].active;
    }

    /// Return grace-complete (consumed_gen>=retire_gen) retired slots fully to free (call before reuse).
    fn reclaimRetired(self: *DynGraph) void {
        const cg = self.consumed_gen.load(.acquire);
        for (&self.slots) |*s| {
            if (s.retired and cg >= s.retire_gen) s.retired = false;
        }
    }

    /// Whether a live (active||retired) handle occupies pool(kind,idx).
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

    /// Add a module and return its handle. Copy value into a pool slot (deferred reset on activate),
    /// clear its signal-port range, bake RT-read fields from spec(). DSP state does not touch other slots.
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
        arr[pidx] = value; // Reset state (DSP state to defaults)
        const base: usize = @as(usize, h) * MAX_OUT;
        @memset(self.sig_a[base..][0..MAX_OUT], 0); // Do not leak residual output from the previous module
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

    /// Remove (retire) a module. Do not destroy RT-read fields; clear staging connections and output;
    /// set retire_gen to the next publish's gen (handle/pool are not reused until grace completes).
    pub fn removeModule(self: *DynGraph, h: Handle) void {
        if (!self.isActive(h)) return;
        self.slots[h].active = false;
        self.slots[h].retired = true;
        self.slots[h].retire_gen = self.gen + 1; // The handle disappears from the next publish's view

        self.stage_in_src[h] = [_]i32{-1} ** MAX_IN; // This handle's input connections
        const base: i32 = @intCast(self.instances[h].out_base);
        const span: i32 = @intCast(MAX_OUT);
        for (&self.stage_in_src) |*ins| { // Other inputs that reference this handle's outputs
            for (ins) |*src| {
                if (src.* >= base and src.* < base + span) src.* = -1;
            }
        }
        if (self.stage_output == @as(i32, h)) self.stage_output = -1;
    }

    /// Connect src_node.out → dst_node.in (kinds must match; single connection = already-connected is an error). Edits staging only.
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

    /// DFS (push dependencies first). A dependency still visiting = a back edge, marked as a delay edge (same policy as graph.zig).
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
            if (!self.slots[owner].active) continue; // Dangling defence (normally cleared by removeModule)
            if (owner == u) {
                in_delayed[u][i] = true; // A self-loop is a delay
                continue;
            }
            switch (colors[owner]) {
                .unvisited => self.dfs(owner, colors, in_delayed, order, order_len),
                .visiting => in_delayed[u][i] = true, // back edge → delay
                .done => {},
            }
        }
        colors[u] = .done;
        order[order_len.*] = u;
        order_len.* += 1;
    }

    /// Topo-sort + cycle-detect + master-validate staging, bake a GraphView, and publish it into the triple-buffer.
    /// Non-RT. No per-call heap alloc (scratch is on the stack).
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

        // Validate the master output here on the non-RT side (do not panic in RT).
        var out: i32 = -1;
        if (self.stage_output >= 0) {
            const oh: Handle = @intCast(self.stage_output);
            if (!self.isActive(oh) or self.instances[oh].n_out < 1) return Error.BadNodeIndex;
            out = self.stage_output;
        }
        view.output = out;
        view.in_src = self.stage_in_src; // Indexed by handle (rows for non-active are unused)
        view.gen = self.gen + 1;

        self.mailbox.publish(view);
        self.last_published = view;
        self.gen += 1;
    }

    /// RT: latch the latest view → record gen → resolve handles via the registry → graph_core.
    /// No alloc/lock/IO/panic/sort. Unpublish / empty view / channels==0 zero-fills.
    ///
    /// Per-block RT path. Rebuild the ProcNode sequence + out_sel **only when view.gen changes** (when gen is unchanged,
    /// reuse the previous block's proc_cache/cached_out_sel. Symmetric with the static Graph baking once in finalize).
    /// Latch of the tap config and the release store of applied_seq are an independent channel from gen, so they run every block
    /// (outside the gen-skip; keep the GUI draw gate alive).
    pub fn processBlock(self: *DynGraph, buf: []f32, frames: u32, channels: u32) void {
        const view = self.mailbox.acquire();
        self.consumed_gen.store(view.gen, .release);
        // D: latch tap config (once per block). A swapped slot resets local_wpos/wpos so residual samples from the
        // old port do not mix into the new port's window. Latch and applied_seq store still run on empty/no-channel
        // (so the GUI draw gate does not stall). Runs every block, independent of gen-skip.
        const any_tap = self.latchTapConfig();
        if (view.node_count == 0 or channels == 0) {
            @memset(buf, 0);
            self.tap.applied_seq.store(self.tap.latched_seq, .release);
            return;
        }
        // When gen is unchanged, skip rebuilding the ProcNode sequence + out_sel. Correctness: gen is monotonic +1 per publish
        // (u64; wrap is effectively impossible) and a GraphView's contents are immutable for a given gen. RT-read fields of
        // handles in the view (vtable/ctx/out_base/n_in/n_out) are immutable for the view's lifetime under RCU grace
        // (no reuse until consumed_gen>=retire_gen; add() only writes free/reclaimed slots = handles not in the current view).
        // So a rebuild for the same gen is bit-identical = skipping does not change the output. cache_valid states this explicitly (no sentinel).
        if (!(self.cache_valid and view.gen == self.cache_gen)) {
            var k: usize = 0;
            while (k < view.node_count) : (k += 1) {
                const h = view.order[k];
                const inst = &self.instances[h];
                self.proc_cache[k] = .{
                    .vtable = inst.vtable,
                    .ctx = inst.ctx,
                    .n_in = inst.n_in,
                    .n_out = inst.n_out,
                    .out_base = inst.out_base,
                    .in_src = view.in_src[h],
                    .in_delayed = view.in_delayed[h],
                };
            }
            self.cached_out_sel = if (view.output >= 0) blk: {
                const oh: Handle = @intCast(view.output);
                break :blk .{ .out_base = self.instances[oh].out_base, .n_out = self.instances[oh].n_out };
            } else null;
            self.cache_gen = view.gen;
            self.cache_valid = true;
            self.rebuild_count +%= 1;
        }
        const procs = self.proc_cache[0..view.node_count];
        // One branch per block only: if any tap slot is active use the tapped path, else the prior path (machine code unchanged).
        if (any_tap) {
            graph_core.processBlockTapped(procs, self.cached_out_sel, self.sample_rate, &self.cur, &self.prev, buf, frames, channels, &self.tap);
        } else {
            graph_core.processBlock(procs, self.cached_out_sel, self.sample_rate, &self.cur, &self.prev, buf, frames, channels);
        }
        // At block end, release-store the latched config's seq (1 store/block; GUI draw gate).
        self.tap.applied_seq.store(self.tap.latched_seq, .release);
    }

    /// acquire and latch the tap config (GUI publish). A swapped slot resets local_wpos=0 + wpos=0
    /// (treat old-port residue as absent). Returns true if any tap slot is active. No alloc/lock on the RT path.
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
                self.tap.slots[s].wpos.store(0, .release); // Show "empty" to the GUI immediately
            }
            // Port kind is fixed, so decim/peak do not change while the port is unchanged (per-block latch cost is small).
            self.tap.latched_decim[s] = cfg.decim[s];
            self.tap.latched_peak[s] = cfg.peak[s];
            if (p >= 0 and @as(usize, @intCast(p)) < MAX_PORTS) any = true;
        }
        return any;
    }

    // --- Test introspection / non-RT config / live atomic params ---
    /// Return a ptr to the live pool slot (the real instance the RT processes; DSP-resident state not on the publish payload).
    ///
    /// Two uses:
    ///   1. Non-RT initial setup before publish or during the grace window (as before).
    ///   2. **Atomic access to fields that are already atomicised, while running** (the "live-param atomic boundary").
    ///      e.g. StepSeq mask/step are `@atomicLoad`/`@atomicStore(.monotonic)`, so a GUI (main-thread) store and the
    ///      RT `process` load share the same live instance as the correct cross-thread channel
    ///      (ptrOf returns exactly the pool slot the RT processes).
    ///
    /// **Writing non-atomic fields while running remains forbidden** (tears against RT reads). Use only on active members
    /// (do not use on handles already removeModule'd by the ledger). Signature and return type are unchanged.
    pub fn ptrOf(self: *DynGraph, comptime k: ModuleKind, h: Handle) *KindType(k) {
        return &self.poolArray(k)[self.slots[h].pool_idx];
    }

    /// Ptr to a read-only live pool slot. For non-RT reference-only paths such as param-descriptor getters.
    /// Callers must pre-validate an active handle (same assumption as ptrOf).
    pub fn ptrOfConst(self: *const DynGraph, comptime k: ModuleKind, h: Handle) *const KindType(k) {
        return &@constCast(self).poolArray(k)[self.slots[h].pool_idx];
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
    /// Cumulative count of actual ProcNode-sequence rebuilds (introspection for verifying gen-skip).
    pub fn rebuildCount(self: *const DynGraph) u64 {
        return self.rebuild_count;
    }
    pub fn currentView(self: *const DynGraph) GraphView {
        return self.last_published;
    }
    pub fn isDelayed(self: *const DynGraph, h: Handle, in_port: usize) bool {
        return self.last_published.in_delayed[h][in_port];
    }

    // --- Read-only introspection for drawing/probes (out of range → null/0; never crash on a raw index) ---
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

    // --- Port activity (best-effort torn read; zero RT impact) ---
    /// Current signal level of output port (h, out) ≈ max(|sig_a[p]|, |sig_b[p]|). Asynchronous best-effort read of
    /// f32s the RT writes (which ping-pong side is latest is undefined, but enough for an activity meter; within
    /// "GUI reads of signal may tear"). `.unordered` atomic load avoids torn while leaving the RT path unchanged (GUI only).
    /// Out of range / inactive → 0 (never crash on a raw index).
    pub fn sigLevel(self: *const DynGraph, h: Handle, out: usize) f32 {
        if (h >= MAX_MODULES or out >= MAX_OUT or !self.slots[h].active) return 0;
        const p = @as(usize, h) * MAX_OUT + out;
        const a = @abs(@atomicLoad(f32, &self.sig_a[p], .unordered));
        const b = @abs(@atomicLoad(f32, &self.sig_b[p], .unordered));
        return @max(a, b);
    }

    // --- Per-port tap (GUI-side API) ---
    /// GUI→RT: publish the tap's port assignment (triple-buffer; no torn; latest-wins; non-blocking).
    pub fn publishTapConfig(self: *DynGraph, cfg: graph_core.TapConfig) void {
        self.tap_mailbox.publish(cfg);
    }
    /// Seq of the config the RT last latched and applied (GUI draw gate).
    pub fn tapAppliedSeq(self: *const DynGraph) u32 {
        return self.tap.applied_seq.load(.acquire);
    }
    /// Total samples written into the slot (acquire; ring writes up to this are visible).
    pub fn tapWpos(self: *const DynGraph, slot: usize) u32 {
        if (slot >= graph_core.TAP_SLOTS) return 0;
        return self.tap.slots[slot].wpos.load(.acquire);
    }
    /// Copy the slot's latest window (up to out.len) into out oldest→newest; return how many were copied.
    /// Ring writes up to the acquired wpos are visible. A torn tail the RT overwrites mid-read is accepted as a display glitch.
    pub fn tapWindow(self: *const DynGraph, slot: usize, out: []f32) usize {
        if (slot >= graph_core.TAP_SLOTS) return 0;
        const w = self.tap.slots[slot].wpos.load(.acquire);
        const avail = @min(@as(usize, w), graph_core.TAP_RING);
        const count = @min(avail, out.len);
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const abs = @as(usize, w) - count + k; // count<=avail<=w so no underflow
            // unordered load paired with the RT unordered store (no torn requirement; races OK; same machine code as a plain load).
            out[k] = @atomicLoad(f32, &self.tap.slots[slot].ring[abs % graph_core.TAP_RING], .unordered);
        }
        return count;
    }

    // --- Main-only preflight accessors (read-only; no RT involvement) ---
    // Does not change the publish/processBlock RT path or the RCU/triple-buffer machinery at all. Returns "how many
    // add() could allocate right now" under the same reclaim condition as add()
    // (live=active || (retired and consumed_gen < retire_gen)), counted non-destructively even before reclaimRetired runs.

    /// Free slots in kind's pool that add could take right now.
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

    /// Free handles add could take right now (MAX_MODULES cap).
    pub fn freeHandleCount(self: *const DynGraph) usize {
        const cg = self.consumed_gen.load(.acquire);
        var used: usize = 0;
        for (self.slots) |s| {
            if (s.active or (s.retired and cg < s.retire_gen)) used += 1;
        }
        return if (used >= MAX_MODULES) 0 else MAX_MODULES - used;
    }
};

/// Proxy size for union-to-largest (max @sizeOf across kinds × MAX_MODULES). Compared in test (e).
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
// tests (no display/audio; part of test-modular)
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

test "dyn(e): typed pools < uniform union (avoid union-to-largest bloat)" {
    // Real total pool size is well below the union-proxy that would lay DelayFx(≈256KB) into every slot.
    try testing.expect(poolsSize() < unionToLargestSize());
    // Also confirm a large gap (at least several×).
    try testing.expect(poolsSize() * 2 < unionToLargestSize());
}

test "dyn(h1/h2): triple-buffer stays untorn under consecutive publish; latest-wins; non-fresh keeps current view" {
    var mb = Mailbox(u32).init(0);
    try testing.expect(mb.indicesArePermutation());
    // A non-fresh consume keeps the initial value
    try testing.expectEqual(@as(u32, 0), mb.acquire().*);
    // Consecutive publish (no consume between) still keeps the permutation invariant; producer does not write the read slot
    mb.publish(10);
    try testing.expect(mb.indicesArePermutation());
    mb.publish(20);
    try testing.expect(mb.indicesArePermutation());
    mb.publish(30);
    try testing.expect(mb.indicesArePermutation());
    // consume takes the latest
    try testing.expectEqual(@as(u32, 30), mb.acquire().*);
    // With no publish, the current view is kept
    try testing.expectEqual(@as(u32, 30), mb.acquire().*);
    try testing.expect(mb.indicesArePermutation());
}

test "dyn(a): minimal patch publish->render is non-silent, finite, bounded; holds under add while running" {
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

    // While running, add an unrelated second VCO (unconnected) → publish → still finite/bounded/non-silent.
    _ = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    try g.publish();
    g.processBlock(&buf, 512, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0);
    for (buf) |s| {
        try testing.expect(std.math.isFinite(s));
        try testing.expect(@abs(s) <= 1.0001);
    }
}

test "dyn(c): state preserved — unrelated add does not reset existing VCO phase (sample-identical)" {
    // ref: render VCO->Output for 2 consecutive blocks.
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

    // test: render the same VCO->Output for 1 block, add+publish an unrelated second VCO, then render.
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
    // Rewire: add an unrelated VCO (no effect on existing v/o connections or state).
    _ = try g.add(.vco, .{ .osc = .{ .waveform = .saw }, .base_hz = 110 });
    try g.publish();
    g.processBlock(&g_b2, 128, 2);

    // block1 must match. If block2 also matches → "no phase reset / no discontinuity at the connection" = state preserved.
    try testing.expectEqualSlices(f32, &ref_b1, &g_b1);
    try testing.expectEqualSlices(f32, &ref_b2, &g_b2);
}

test "dyn(c2): DelayFx tail — disconnecting input keeps the immediate tail continuous (state preserved)" {
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
    g.processBlock(&buf, 4800, 2); // Fill the delay line

    // Disconnect vco→delay (delay input 0) → publish. The tail (feedback) remains, so the next audio is still non-silent.
    g.disconnect(dly, 0);
    try g.publish();
    var tail: [480 * 2]f32 = undefined;
    g.processBlock(&tail, 480, 2);
    try testing.expect(rmsEven(&tail, 2) > 0.0); // Tail does not cut off
    for (tail) |s| try testing.expect(std.math.isFinite(s));
}

test "dyn(b): deterministic — same op sequence twice yields matching output and final GraphView" {
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
            // Extra connection
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
    // Final GraphView matches (excluding gen)
    try testing.expectEqual(va.node_count, vb.node_count);
    try testing.expectEqual(va.output, vb.output);
    try testing.expectEqualSlices(u16, va.order[0..va.node_count], vb.order[0..vb.node_count]);
    try testing.expectEqualSlices([MAX_IN]i32, &va.in_src, &vb.in_src);
    try testing.expectEqualSlices([MAX_IN]bool, &va.in_delayed, &vb.in_delayed);
}

test "dyn(b2): long op sequence (connect/disconnect/remove/reuse) applied twice is deterministic" {
    // Operation sequence mimicking UI live rewiring: build→render→add connection→render→disconnect→render→remove→publish→render→
    // re-add after grace→render. Apply the same sequence to two graphs with a fixed seed (module defaults); output and final View must match.
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
            // Add an LFO to modulate cutoff
            const lfo = try g.add(.lfo, .{ .rate_hz = 1.0 });
            try g.connect(lfo, 0, f, 1);
            try g.publish();
            g.processBlock(&tmp, 128, 2);
            // Disconnect (remove LFO→cutoff)
            g.disconnect(f, 1);
            try g.publish();
            g.processBlock(&tmp, 128, 2);
            // Remove the LFO → publish → render advances grace
            g.removeModule(lfo);
            try g.publish();
            g.processBlock(&tmp, 128, 2);
            // Reuse the grace-complete slot (different module)
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

test "dyn(f): single connection / kind match / cycle delay / error distinction" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v1 = try g.add(.vco, .{});
    const v2 = try g.add(.vco, .{});
    const m = try g.add(.mixer, .{});
    const eg = try g.add(.env_gen, .{});
    // Single connection: a second cable into the same input is an error
    try g.connect(v1, 0, m, 0);
    try testing.expectError(Error.InputAlreadyConnected, g.connect(v2, 0, m, 0));
    try g.connect(v2, 0, m, 1); // A different port is OK
    // Kind mismatch: audio(out) -> gate(in) is rejected
    try testing.expectError(Error.PortKindMismatch, g.connect(v1, 0, eg, 0));

    // Cycle: mixer out into its own in1 (self-loop) → delay edge.
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

test "dyn(f2a): pool exhaustion is PoolFull (even when handle space remains)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    // Exhaust the output pool (default cap=2; scales with -Dmax-modules).
    // Confirm PoolFull while handle space still has room.
    const cap = poolCap(.output);
    var i: usize = 0;
    while (i < cap) : (i += 1) _ = try g.add(.output, .{});
    try testing.expectError(Error.PoolFull, g.add(.output, .{}));
    try testing.expect(g.activeCount() < MAX_MODULES);
}

test "dyn(f2b): each planned pool can be filled to capacity and exhausts on the next add" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const kinds = [_]ModuleKind{ .slew, .sample_hold, .comparator, .ring_mod, .logic };
    inline for (kinds) |k| {
        const cap = poolCap(k);
        var i: usize = 0;
        while (i < cap) : (i += 1) _ = try g.add(k, .{});
        try testing.expectEqual(@as(usize, 0), g.poolFreeCount(k));
        try testing.expectError(Error.PoolFull, g.add(k, .{}));
    }
}

test "dyn(f2c): a sounding path connecting the five kinds is finite and non-zero" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();

    const vco_a = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 220 });
    const vco_b = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 330 });
    const lfo = try g.add(.lfo, .{});
    const clock = try g.add(.clock, .{});
    const divider = try g.add(.clock_divider, .{});
    const slew = try g.add(.slew, .{});
    const sh = try g.add(.sample_hold, .{});
    const cmp = try g.add(.comparator, .{});
    const rm = try g.add(.ring_mod, .{});
    const logic = try g.add(.logic, .{});
    const output = try g.add(.output, .{});

    try g.connect(vco_a, 0, rm, 0);
    try g.connect(vco_b, 0, rm, 1);
    try g.connect(rm, 0, output, 0);
    try g.connect(lfo, 0, slew, 0);
    try g.connect(lfo, 0, sh, 0);
    try g.connect(clock, 0, sh, 1);
    try g.connect(lfo, 0, cmp, 0);
    try g.connect(slew, 0, cmp, 1);
    try g.connect(cmp, 0, logic, 0);
    try g.connect(divider, 0, logic, 1);
    try g.connect(clock, 0, divider, 0);
    g.setOutput(output);
    try g.publish();

    var buf: [4096 * 2]f32 = undefined;
    g.processBlock(&buf, 4096, 2);
    var nonzero = false;
    for (buf) |sample| {
        try testing.expect(std.math.isFinite(sample));
        if (@abs(sample) > 1e-6) nonzero = true;
    }
    try testing.expect(nonzero);
}

test "dyn(f2d): the five kinds process multiple blocks under FailingAllocator" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const vco_a = try g.add(.vco, .{});
    const vco_b = try g.add(.vco, .{});
    const lfo = try g.add(.lfo, .{});
    const clock = try g.add(.clock, .{});
    const divider = try g.add(.clock_divider, .{});
    const slew = try g.add(.slew, .{});
    const sh = try g.add(.sample_hold, .{});
    const cmp = try g.add(.comparator, .{});
    const rm = try g.add(.ring_mod, .{});
    const logic = try g.add(.logic, .{});
    const output = try g.add(.output, .{});
    try g.connect(vco_a, 0, rm, 0);
    try g.connect(vco_b, 0, rm, 1);
    try g.connect(rm, 0, output, 0);
    try g.connect(lfo, 0, slew, 0);
    try g.connect(lfo, 0, sh, 0);
    try g.connect(clock, 0, sh, 1);
    try g.connect(lfo, 0, cmp, 0);
    try g.connect(slew, 0, cmp, 1);
    try g.connect(cmp, 0, logic, 0);
    try g.connect(divider, 0, logic, 1);
    try g.connect(clock, 0, divider, 0);
    g.setOutput(output);
    try g.publish();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    g.allocator = failing.allocator();
    var buf: [1024 * 2]f32 = undefined;
    var block: usize = 0;
    while (block < 16) : (block += 1) {
        g.processBlock(&buf, 1024, 2);
        for (buf) |sample| try testing.expect(std.math.isFinite(sample));
    }
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    g.allocator = testing.allocator;
}

test "dyn(f2b): handle-space exhaustion is TooManyModules (even when the pool has room)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    // Use only half the mixer pool; fill remaining handles with other kinds (works for any -Dmax-modules N).
    // At default N=48, mixer_n=4 and poolCap(mixer)=8 match the prior test shape.
    const mixer_n = poolCap(.mixer) / 2;
    var mi: usize = 0;
    while (mi < mixer_n) : (mi += 1) _ = try g.add(.mixer, .{});
    var left = MAX_MODULES - mixer_n;
    // poolCap needs a comptime kind. Fill each kind in its own block.
    {
        const take = @min(left, poolCap(.vco));
        var j: usize = 0;
        while (j < take) : (j += 1) _ = try g.add(.vco, .{});
        left -= take;
    }
    {
        const take = @min(left, poolCap(.vca));
        var j: usize = 0;
        while (j < take) : (j += 1) _ = try g.add(.vca, .{});
        left -= take;
    }
    {
        const take = @min(left, poolCap(.env_gen));
        var j: usize = 0;
        while (j < take) : (j += 1) _ = try g.add(.env_gen, .{});
        left -= take;
    }
    {
        const take = @min(left, poolCap(.vcf));
        var j: usize = 0;
        while (j < take) : (j += 1) _ = try g.add(.vcf, .{});
        left -= take;
    }
    {
        const take = @min(left, poolCap(.lfo));
        var j: usize = 0;
        while (j < take) : (j += 1) _ = try g.add(.lfo, .{});
        left -= take;
    }
    {
        const take = @min(left, poolCap(.step_seq));
        var j: usize = 0;
        while (j < take) : (j += 1) _ = try g.add(.step_seq, .{});
        left -= take;
    }
    try testing.expectEqual(@as(usize, 0), left);
    try testing.expectEqual(@as(usize, MAX_MODULES), g.activeCount());
    try testing.expect(g.poolFreeCount(.mixer) > 0);
    // Handle space full → TooManyModules even for a mixer that still has pool room.
    try testing.expectError(Error.TooManyModules, g.add(.mixer, .{}));
}

test "dyn(d): RT zero allocation — processBlock/publish never touch self.allocator (FailingAllocator)" {
    // create uses the normal allocator. Then swap g.allocator for a FailingAllocator with fail_index=0 and run
    // processBlock (RT path) and publish (non-RT but no per-call alloc). Any alloc via self.allocator fails immediately
    // with OutOfMemory. Restore the normal allocator before destroy.
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
    const target: u64 = 96_000; // ~2s @48k (run under failing)
    while (rendered < target) : (rendered += chunk) {
        g.processBlock(&buf, chunk, 2); // If it allocates, FailingAllocator catches it
        for (buf) |s| {
            try testing.expect(std.math.isFinite(s));
            try testing.expect(@abs(s) <= 1.0001);
        }
    }
    // Confirm publish also does no per-call alloc under failing (scratch is on the stack).
    _ = try g.add(.lfo, .{});
    try g.publish();
    g.processBlock(&buf, chunk, 2);
    // Confirm FailingAllocator was never called (= zero allocations).
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);

    g.allocator = testing.allocator; // Restore for destroy
}

test "dyn(i): poolFreeCount/freeHandleCount — free counts before add match what add can actually take (including reclaim)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const cap = poolCap(.output);
    try testing.expectEqual(cap, g.poolFreeCount(.output));
    try testing.expectEqual(@as(usize, MAX_MODULES), g.freeHandleCount());

    _ = try g.add(.output, .{});
    try testing.expectEqual(cap - 1, g.poolFreeCount(.output));
    try testing.expectEqual(@as(usize, MAX_MODULES - 1), g.freeHandleCount());

    // 0 when the pool is exhausted (consistent with TooManyModules/PoolFull). Cap changes with -Dmax-modules.
    var last: Handle = 0;
    var i: usize = 1; // One already added
    while (i < cap) : (i += 1) last = try g.add(.output, .{});
    try testing.expectEqual(@as(usize, 0), g.poolFreeCount(.output));

    // Right after remove (before publish/consume) grace is incomplete = still "in use" (not reclaimed).
    g.removeModule(last);
    try testing.expectEqual(@as(usize, 0), g.poolFreeCount(.output));

    // publish + processBlock lets consumed_gen catch up to retire_gen → free count returns as if reclaimed.
    try g.publish();
    var buf: [64 * 2]f32 = undefined;
    g.processBlock(&buf, 64, 2);
    try testing.expectEqual(@as(usize, 1), g.poolFreeCount(.output));
}

test "dyn(h3): RCU grace — do not reuse the same handle after remove while grace is incomplete" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    var buf: [64 * 2]f32 = undefined;
    g.processBlock(&buf, 64, 2); // consumed_gen=1 (v is still in view gen1)

    // Remove v. retire_gen = gen+1 (= 2; disappears from the next publish's view).
    g.removeModule(v);
    // Grace incomplete (consumed_gen=1 < retire_gen=2): add must not reuse v (different handle).
    const h_other = try g.add(.vco, .{ .osc = .{ .waveform = .square }, .base_hz = 220 });
    try testing.expect(h_other != v);
    g.removeModule(h_other);
}

test "dyn(h4): RCU grace — after grace, reuse the same handle; signal port range is cleared so residue does not leak" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    var buf: [256 * 2]f32 = undefined;
    g.processBlock(&buf, 256, 2); // Non-zero sine remains in v's output ports (both sig_a/sig_b)

    // v's port range is actually non-zero (= state in which the later clear can be verified).
    const base: usize = @as(usize, v) * MAX_OUT;
    var pre_nonzero = false;
    for (g.sig_a[base..][0..MAX_OUT]) |x| {
        if (x != 0) pre_nonzero = true;
    }
    for (g.sig_b[base..][0..MAX_OUT]) |x| {
        if (x != 0) pre_nonzero = true;
    }
    try testing.expect(pre_nonzero);

    // Remove v → publish (gen advances; disappears from the view) → processBlock lifts consumed_gen to >= retire_gen.
    g.removeModule(v);
    try g.publish();
    g.processBlock(&buf, 256, 2); // consumed_gen reached retire_gen → v is reclaimable

    // After grace, add deterministically reuses the smallest free handle (= v).
    const reuse = try g.add(.vca, .{ .gain = 1.0 });
    try testing.expectEqual(v, reuse);
    // Right after reuse (before process), v's old port range is cleared (residue does not leak into the new module).
    for (g.sig_a[base..][0..MAX_OUT]) |x| try testing.expectEqual(@as(f32, 0), x);
    for (g.sig_b[base..][0..MAX_OUT]) |x| try testing.expectEqual(@as(f32, 0), x);

    try g.publish();
    g.processBlock(&buf, 256, 2);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}

// ---- Per-port tap (RT properties; offline single-thread determinism) ----

/// Build a TapConfig with one port on slot0 (test helper).
fn tapCfg(seq: u32, port: i32) graph_core.TapConfig {
    var c = graph_core.TapConfig{ .seq = seq };
    c.ports[0] = port;
    return c;
}

test "dyn(tap-a): audio output is bit-identical with tap on/off (tap is non-invasive)" {
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
    try testing.expectEqualSlices(f32, &a, &b); // tap is non-invasive to buf
}

test "dyn(tap-b): tap ring is deterministic, matches decimation rate, non-constant from an oscillator" {
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
    try testing.expectEqual(@as(u32, F / graph_core.TAP_DECIM), w1); // Matches the decimation rate (no wrap yet)
    try testing.expectEqual(w1, w2);
    const n = @min(@as(usize, w1), graph_core.TAP_RING);
    try testing.expectEqualSlices(f32, r1[0..n], r2[0..n]); // Deterministic
    var mn: f32 = 0;
    var mx: f32 = 0;
    for (r1[0..n]) |x| {
        mn = @min(mn, x);
        mx = @max(mx, x);
    }
    try testing.expect(mn < 0 and mx > 0); // Oscillating (not constant)
}

test "dyn(tap-c): processBlock with tap on + config publish is zero-allocation" {
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
        g.publishTapConfig(tapCfg(seq, port)); // publish also does not allocate
        seq += 1;
        g.processBlock(&buf, chunk, 2);
        for (buf) |s| try testing.expect(std.math.isFinite(s));
    }
    try testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    g.allocator = testing.allocator;
}

test "dyn(tap-d): config swap / remove/reuse stays finite and resets the slot (no old-port mix-in)" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v1 = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const v2 = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 110 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v1, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    var buf: [512 * 2]f32 = undefined;

    // slot0 = v1 → 128 samples written over 512 frames.
    g.publishTapConfig(tapCfg(1, @intCast(@as(u32, v1) * MAX_OUT)));
    g.processBlock(&buf, 512, 2);
    try testing.expectEqual(@as(u32, 512 / graph_core.TAP_DECIM), g.tapWpos(0));
    try testing.expectEqual(@as(u32, 1), g.tapAppliedSeq());

    // Swap slot0 to v2 → next block resets wpos to 0 and only counts new writes (does not keep growing from 128).
    g.publishTapConfig(tapCfg(2, @intCast(@as(u32, v2) * MAX_OUT)));
    g.processBlock(&buf, 256, 2);
    try testing.expectEqual(@as(u32, 256 / graph_core.TAP_DECIM), g.tapWpos(0)); // Reset done
    try testing.expectEqual(@as(u32, 2), g.tapAppliedSeq());

    // remove + publish + reuse still finite; no crash.
    g.removeModule(v1);
    try g.publish();
    g.processBlock(&buf, 256, 2);
    for (buf) |s| try testing.expect(std.math.isFinite(s));
}

test "dyn(tap-e): gate peak-decimation catches 1-sample-wide pulses without missing them" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const clk = try g.add(.clock, .{ .bpm = 240, .ppqn = 8 }); // High-rate ticks (1-sample-wide triggers)
    const o = try g.add(.output, .{});
    g.setOutput(o);
    try g.publish(); // Even unconnected, every active node is in order and evaluated every sample (clock.out0 is written)
    // slot0 = clock.out0, coarse decim + peak. Plain decimation would hit a 1/256 pulse rarely; max still catches it.
    var cfg = graph_core.TapConfig{ .seq = 1 };
    cfg.ports[0] = @intCast(@as(u32, clk) * MAX_OUT);
    cfg.decim[0] = 256;
    cfg.peak[0] = true;
    g.publishTapConfig(cfg);
    var buf: [4096 * 2]f32 = undefined;
    var i: usize = 0;
    while (i < 12) : (i += 1) g.processBlock(&buf, 4096, 2); // ~1s (covers many ticks)
    var win: [graph_core.TAP_RING]f32 = undefined;
    const n = g.tapWindow(0, &win);
    var mx: f32 = 0;
    for (win[0..n]) |v| mx = @max(mx, v);
    try testing.expect(mx > 0.5); // Gate pulses are captured as window maxima
}

test "dyn(tap-cacheline): GUI-write region (tap_mailbox) and RT-write region (tap) are on separate cache lines" {
    const cl = std.atomic.cache_line;
    const mb = @offsetOf(DynGraph, "tap_mailbox");
    const tp = @offsetOf(DynGraph, "tap");
    try testing.expect(mb % cl == 0);
    try testing.expect(tp % cl == 0);
    const diff = if (tp > mb) tp - mb else mb - tp;
    try testing.expect(diff >= cl); // Separate lines (isolate the GUI×RT false-sharing pair)
}

// ============================================================================
// ProcNode sequence + out_sel gen-skip (pin the "skip" performance property in a test)
// ============================================================================

test "dyn(cache-1): same-gen consecutive blocks rebuild once; gen advance rebuilds" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();

    var buf: [128 * 2]f32 = undefined;
    g.processBlock(&buf, 128, 2);
    g.processBlock(&buf, 128, 2);
    g.processBlock(&buf, 128, 2);
    try testing.expectEqual(@as(u64, 1), g.rebuildCount()); // 3 blocks → 1 rebuild

    // Re-publish (gen advances) → also pin that a rebuild happens even when contents are unchanged.
    _ = try g.add(.lfo, .{});
    try g.publish();
    g.processBlock(&buf, 128, 2);
    try testing.expectEqual(@as(u64, 2), g.rebuildCount());
}

test "dyn(cache-2): skip path and per-block rebuild path outputs are bit-identical" {
    // A: one publish → 2 consecutive blocks (block 2 takes the cache-skip path).
    var ga = try DynGraph.create(testing.allocator, 48000);
    defer ga.destroy();
    {
        const v = try ga.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 330 });
        const f = try ga.add(.vcf, .{ .cutoff = 900, .resonance = 2.0, .mode = .lowpass });
        const o = try ga.add(.output, .{ .soft_clip = false });
        try ga.connect(v, 0, f, 0);
        try ga.connect(f, 0, o, 0);
        ga.setOutput(o);
        try ga.publish();
    }
    var a1: [128 * 2]f32 = undefined;
    var a2: [128 * 2]f32 = undefined;
    ga.processBlock(&a1, 128, 2);
    ga.processBlock(&a2, 128, 2); // skip path
    try testing.expectEqual(@as(u64, 1), ga.rebuildCount());

    // B: same topology; re-publish between blocks (contents unchanged, gen++) so every block takes the rebuild path.
    // publish does not touch DSP state (VCO phase etc.), so the output must be bit-identical to A.
    var gb = try DynGraph.create(testing.allocator, 48000);
    defer gb.destroy();
    {
        const v = try gb.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 330 });
        const f = try gb.add(.vcf, .{ .cutoff = 900, .resonance = 2.0, .mode = .lowpass });
        const o = try gb.add(.output, .{ .soft_clip = false });
        try gb.connect(v, 0, f, 0);
        try gb.connect(f, 0, o, 0);
        gb.setOutput(o);
        try gb.publish();
    }
    var b1: [128 * 2]f32 = undefined;
    var b2: [128 * 2]f32 = undefined;
    gb.processBlock(&b1, 128, 2);
    try gb.publish(); // Force rebuild via gen++
    gb.processBlock(&b2, 128, 2);
    try testing.expectEqual(@as(u64, 2), gb.rebuildCount());

    try testing.expectEqualSlices(f32, &a1, &b1);
    try testing.expectEqualSlices(f32, &a2, &b2); // skip(a2) == rebuild(b2): catch stale cache/swap leaks
}

test "dyn(cache-3): unpublished processBlock does not dirty the cache; a later publish rebuilds correctly" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    var buf: [128 * 2]f32 = undefined;
    // Not yet published (empty view) → zero-fill; do not touch the cache.
    g.processBlock(&buf, 128, 2);
    try testing.expectEqual(@as(u64, 0), g.rebuildCount());
    for (buf) |s| try testing.expectEqual(@as(f32, 0), s);

    // publish → non-silent; 1 rebuild (also confirms the empty path did not set cache_valid).
    const v = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const o = try g.add(.output, .{ .soft_clip = false });
    try g.connect(v, 0, o, 0);
    g.setOutput(o);
    try g.publish();
    g.processBlock(&buf, 128, 2);
    try testing.expectEqual(@as(u64, 1), g.rebuildCount());
    try testing.expect(rmsEven(&buf, 2) > 0.0);
}

test "dyn(cache-5): master-output switch (gen advance) makes cached_out_sel follow" {
    var g = try DynGraph.create(testing.allocator, 48000);
    defer g.destroy();
    // A=VCO sine (non-zero source), B=unconnected Mixer (no inputs = output 0). Both are evaluated every sample
    // as active nodes (publish topo is not reachability-limited). Which one master reads changes the output.
    const a = try g.add(.vco, .{ .osc = .{ .waveform = .sine }, .base_hz = 440 });
    const b = try g.add(.mixer, .{ .gain = 1.0 });
    g.setOutput(a);
    try g.publish();
    var buf: [256 * 2]f32 = undefined;
    g.processBlock(&buf, 256, 2);
    try testing.expect(rmsEven(&buf, 2) > 0.0); // master=A → non-silent sine
    const rc1 = g.rebuildCount();

    // Switch master to B (unconnected Mixer=0) → gen advances, cached_out_sel follows, output must become 0.
    // An implementation that updates only the ProcNode sequence and forgets to rebake out_sel would keep reading A's sine and fail.
    g.setOutput(b);
    try g.publish();
    g.processBlock(&buf, 256, 2);
    try testing.expectEqual(rc1 + 1, g.rebuildCount()); // Rebuild on gen advance
    for (buf) |s| try testing.expectEqual(@as(f32, 0), s); // master=B → all samples 0
}
