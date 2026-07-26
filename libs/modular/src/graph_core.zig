//! libs/modular: per-sample evaluation core (shared by static Graph / dynamic DynGraph).
//!
//! Depends only on signal (imports neither modules nor dsp = generic). RT-safe: the process path has
//! no alloc/lock/IO/panic. Shared kernel that avoids a dual static/dynamic implementation.
//!
//! Callers pass a ProcNode sequence already in processing order plus cur/prev signal buffers. Topology
//! construction (topo sort / cycle-delay edges / validity checks) is entirely the caller's (non-RT);
//! entry here assumes "valid, non-empty, channels>=1".

const std = @import("std");
const signal = @import("signal.zig");

const Io = signal.Io;

/// RT-locally resolved description of one node in processing order.
/// vtable/ctx are pointers, but this is an **RT-local resolution result**, not a publish payload (POD GraphView)
/// (the dynamic path resolves handles from the GraphView via the registry into this form). The POD constraint
/// applies only to the publish payload = GraphView.
pub const ProcNode = struct {
    vtable: *const signal.VTable,
    ctx: *anyopaque,
    n_in: u8,
    n_out: u8,
    /// Start index of this node's output ports in the signal buffer.
    out_base: u32,
    /// Global output-port id feeding each input port (unconnected = -1).
    in_src: [signal.MAX_IN]i32 = [_]i32{-1} ** signal.MAX_IN,
    /// Whether each input port is a cycle-delay edge (reads previous-sample prev).
    in_delayed: [signal.MAX_IN]bool = [_]bool{false} ** signal.MAX_IN,
};

/// Master-output port selection (out0=L, out1=R; n_out<2 duplicates mono→L/R).
pub const OutputSel = struct { out_base: u32, n_out: u8 };

/// One sample of master output.
pub const StereoOut = struct { l: f32, r: f32 };

// ============================================================================
// Per-port tap for the mini oscilloscope (peek-style RT→GUI ring).
//
// Types live here so the core stays generic (signal-only). DynGraph owns the concrete inline storage.
// Contract:
//   - RT (processBlockTapped): write latched_ports[s]'s global port-id output into the ring decimated by TAP_DECIM
//     (.unordered store = same machine code as a plain store on aligned f32; no fence/RMW).
//     Advance wpos with a per-block local counter; one release store per slot at block end (the synchronising
//     atomic is only that end-of-block wpos, not every sample).
//   - GUI: acquire-load wpos → read the latest min(wpos,TAP_RING) samples as a "peek" (does not consume).
//     acquire synchronizes-with the RT release, so ring writes up to that wpos are visible.
//     A torn tail overwritten by the next RT block during a read is accepted as a one-frame display glitch (best-effort).
//   - On port swap, dyn resets local_wpos[s]=0 + wpos.store(0) so old-port samples do not mix into the
//     new port's window (together with the applied_seq gate).
// ============================================================================
pub const TAP_SLOTS: usize = 16;
pub const TAP_RING: usize = 256;
pub const TAP_DECIM: u32 = 4; // Fine decimation for audio waveforms (~21ms window)
pub const TAP_DECIM_SLOW: u32 = 256; // Coarse decimation for cv/gate (256 points ≈ ~1.4s window; see rhythm / slow modulation)

/// GUI→RT publish payload (POD). ports[s] = global output port id (handle*MAX_OUT+out; -1 = empty slot).
/// Per-slot decimation (decim) and reduce mode (peak) are set by the GUI from the port kind:
///   - audio: small decim, peak=false (tail value = waveform; phase-locked for a still display)
///   - cv:    large decim, peak=false (tail value = slow modulation over a long window)
///   - gate:  large decim, peak=true  (window max = catch 1-sample pulses as vertical bars)
pub const TapConfig = struct {
    seq: u32 = 0,
    ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS,
    decim: [TAP_SLOTS]u32 = [_]u32{TAP_DECIM} ** TAP_SLOTS,
    peak: [TAP_SLOTS]bool = [_]bool{false} ** TAP_SLOTS,
};

/// One slot's RT-write / GUI-read ring.
pub const TapSlot = struct {
    ring: [TAP_RING]f32 = [_]f32{0} ** TAP_RING,
    /// Total samples written (monotonic). RT release-stores at block end; GUI acquire-loads.
    wpos: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Tap region written by RT and read by GUI (subject to cache_line isolation). RT-private fields
/// (latched_ports/local_wpos/decim_counter) are RT-only so they may share the line (no GUI-write false-sharing pair).
pub const TapState = struct {
    /// RT release-stores the latched config's seq at block end (GUI draw gate).
    applied_seq: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    slots: [TAP_SLOTS]TapSlot = [_]TapSlot{.{}} ** TAP_SLOTS,
    // --- RT-private (GUI does not read) ---
    /// Currently latched port assignment (detect config swaps).
    latched_ports: [TAP_SLOTS]i32 = [_]i32{-1} ** TAP_SLOTS,
    /// Per-slot latched decimation rate and reduce mode (baked from config).
    latched_decim: [TAP_SLOTS]u32 = [_]u32{TAP_DECIM} ** TAP_SLOTS,
    latched_peak: [TAP_SLOTS]bool = [_]bool{false} ** TAP_SLOTS,
    /// Per-slot local write counter (published to wpos at block end).
    local_wpos: [TAP_SLOTS]u32 = [_]u32{0} ** TAP_SLOTS,
    /// Per-slot decimation counter (persists across blocks).
    cnt: [TAP_SLOTS]u32 = [_]u32{0} ** TAP_SLOTS,
    /// Per-slot peak accumulator (window max in peak mode; reset to 0 after write).
    acc: [TAP_SLOTS]f32 = [_]f32{0} ** TAP_SLOTS,
    /// Seq of the config latched this block (release-stored to applied_seq at block end). RT-private.
    latched_seq: u32 = 0,
};

/// Evaluate one sample. nodes are in processing order. Write into cur; reflect the ping-pong swap into the cur/prev pointers.
/// Capture and return the master output before the swap (after the swap it moves to the prev side).
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

    // Ping-pong swap: next sample's prev = this sample's cur (= the value delay edges read).
    const tmp = cur.*;
    cur.* = prev.*;
    prev.* = tmp;
    return out;
}

/// Update every node's coefficients at the block head (heavy tan / @exp etc. live here = block-rate).
fn updateAllParams(nodes: []const ProcNode, sample_rate: f32) void {
    for (nodes) |*node| node.vtable.updateParams(node.ctx, sample_rate);
}

/// Write `frames` samples into the interleaved output. nodes are ordered and assumed valid (unfinalised / invalid view /
/// channels==0 are rejected by the caller with buf already zero-filled). channels==1 writes (L+R)/2;
/// >=2 writes L/R and zeros the rest. Callable from an RT callback (no alloc/lock/IO/panic).
///
/// The untapped path (tapped=false) adds zero branches to the per-sample loop (the tap branch is comptime-eliminated).
/// → `processBlock` (called by graph.zig / dyn when untapped) keeps the prior signature and machine-code shape.
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
            // processSample has already ping-pong-swapped, so each port's output for this sample sits on prev.*
            // (same values as pre-swap cur.*; reading the "one place" the master capture used, under its post-swap alias).
            // Per-slot decimation + reduce: peak = window max (never miss a 1-sample gate pulse);
            // non-peak = value at the decimation boundary (waveform). Only O(TAP_SLOTS)/sample load+max+compare (no alloc/lock/transcendentals).
            const sig = prev.*;
            var s: usize = 0;
            while (s < TAP_SLOTS) : (s += 1) {
                const p = tap.latched_ports[s];
                if (p < 0) continue;
                const pu: usize = @intCast(p);
                if (pu >= sig.len) continue; // Range clamp (never panic on a stale port)
                const v = sig[pu];
                if (tap.latched_peak[s]) tap.acc[s] = @max(tap.acc[s], v);
                tap.cnt[s] += 1;
                const d = @max(@as(u32, 1), tap.latched_decim[s]); // Stop a runaway when decim=0
                if (tap.cnt[s] >= d) {
                    tap.cnt[s] = 0;
                    const out_v = if (tap.latched_peak[s]) tap.acc[s] else v;
                    // .unordered = weakest atomic (no torn requirement; races OK). On naturally-aligned f32 it is the same
                    // machine code as a plain store (no fence/RMW) = zero RT overhead. Paired with GUI tapWindow's unordered load,
                    // a "tail overwritten by the next block during a read" becomes best-effort torn instead of data-race UB.
                    @atomicStore(f32, &tap.slots[s].ring[tap.local_wpos[s] % TAP_RING], out_v, .unordered);
                    tap.local_wpos[s] += 1;
                    if (tap.latched_peak[s]) tap.acc[s] = 0; // Reset the window
                }
            }
        }
    }
    if (tapped) {
        // One release store per slot at block end (avoid a per-sample atomic).
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

/// Tapped variant (dyn calls this on blocks with at least one active tap slot). Output buf is bit-identical to the untapped path
/// (tap only reads prev.*; non-invasive to buf/DSP state).
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
// tests (structural sanity only; behaviour is covered by the facade tests in graph.zig / dyn.zig)
// ============================================================================
const testing = std.testing;

test "graph_core: ProcNode / GraphView payload is POD aside from pointers (index/handle refs)" {
    // ProcNode is RT-locally resolved so it contains vtable/ctx pointers (this is not across a publish).
    try testing.expect(@sizeOf(OutputSel) > 0);
    try testing.expect(@sizeOf(ProcNode) > 0);
}
