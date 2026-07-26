//! libs/modular: signal conventions for the modular graph engine (a leaf; imports neither dsp nor graph).
//!
//! Every signal is f32, but its meaning is fixed (see docs/modular.md):
//!   - audio  : roughly -1..1 (brief overshoot is allowed; managed at the final Output)
//!   - cv     : unipolar 0..1 by default; bipolar (-1..1) must be stated by the consumer
//!   - gate   : 0/1. High when at or above gate_threshold (0.5)
//!   - trigger: rising edge when gate crosses 0.5 upward
//!   - pitch  : pitch_cv (1.0/oct, 0 = reference pitch_base_hz). Hz conversion is confined to the VCO/Quantizer boundary

const std = @import("std");

/// Port kind. connect allows same-kind connections only.
pub const PortKind = enum { audio, cv, gate };

/// Per-module input / output port caps (comptime constants for fixed allocation).
pub const MAX_IN: usize = 8;
pub const MAX_OUT: usize = 4;

/// Threshold at which a gate is considered high.
pub const gate_threshold: f32 = 0.5;

/// Reference pitch for pitch_cv (0 = C4 ≈ middle C).
pub const pitch_base_hz: f32 = 261.625565;

/// Convert pitch_cv (1.0/oct) to Hz. Boundary function so Hz does not flow through the graph.
pub inline fn pitchToHz(base_hz: f32, pitch_cv: f32) f32 {
    return base_hz * @exp2(pitch_cv);
}

/// Whether a gate value is high.
pub inline fn gateHigh(v: f32) bool {
    return v >= gate_threshold;
}

/// View through which a module's process accesses one sample of I/O.
/// inputs / connected / outputs are temporary slices provided by the graph (do not retain them across process).
pub const Io = struct {
    /// Value of each input port (0 if unconnected). Length = number of input ports.
    inputs: []const f32,
    /// Whether each input port is connected (used to fall back to a param when a CV is unconnected).
    connected: []const bool,
    /// Write destination for each output port. Length = number of output ports.
    outputs: []f32,
    /// Effective sample rate (Hz).
    sample_rate: f32,
};

/// Module vtable. Separates process (per-sample, lightweight) from updateParams (block head, coefficient recompute)
/// (do not run heavy tan() and similar per sample).
pub const VTable = struct {
    process: *const fn (ctx: *anyopaque, io: *Io) void,
    updateParams: *const fn (ctx: *anyopaque, sample_rate: f32) void,
};

/// no-op for modules that do not implement updateParams.
pub fn noopUpdate(_: *anyopaque, _: f32) void {}

/// Module descriptor passed to addModule. ctx is a pointer to the concrete module struct (caller owns its lifetime).
pub const NodeSpec = struct {
    vtable: *const VTable,
    ctx: *anyopaque,
    in_kinds: []const PortKind,
    out_kinds: []const PortKind,
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "pitchToHz: +1 oct doubles, -1 oct halves, 0 is base" {
    try testing.expectApproxEqAbs(pitch_base_hz, pitchToHz(pitch_base_hz, 0.0), 1e-3);
    try testing.expectApproxEqAbs(pitch_base_hz * 2.0, pitchToHz(pitch_base_hz, 1.0), 1e-3);
    try testing.expectApproxEqAbs(pitch_base_hz * 0.5, pitchToHz(pitch_base_hz, -1.0), 1e-3);
}

test "gateHigh: threshold at 0.5" {
    try testing.expect(!gateHigh(0.0));
    try testing.expect(!gateHigh(0.49));
    try testing.expect(gateHigh(0.5));
    try testing.expect(gateHigh(1.0));
}
