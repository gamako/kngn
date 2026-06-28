//! libs/modular: モジュラー・グラフエンジンの信号規約（leaf。dsp も graph も import しない）。
//!
//! 全信号は f32 だが「意味」を固定する（docs/plans/modular-synth-plan.md §4.1）:
//!   - audio  : 概ね -1..1（瞬間的超過は可。最終 Output で管理）
//!   - cv     : 既定 unipolar 0..1。bipolar(-1..1) は使う側で明示
//!   - gate   : 0/1。しきい値 gate_threshold(0.5) で high 判定
//!   - trigger: gate が 0.5 を上向きにまたぐ立ち上がり
//!   - pitch  : pitch_cv（1.0/oct, 0 = 基準音 pitch_base_hz）。Hz 変換は VCO/Quantizer 境界に閉じ込める

const std = @import("std");

/// ポート種別。connect 時に同種のみ接続を許す。
pub const PortKind = enum { audio, cv, gate };

/// 1 モジュールあたりの入力 / 出力ポート上限（固定確保のため comptime 定数）。
pub const MAX_IN: usize = 8;
pub const MAX_OUT: usize = 4;

/// gate を high と判定するしきい値。
pub const gate_threshold: f32 = 0.5;

/// pitch_cv の基準音（0 = C4 ≒ middle C）。
pub const pitch_base_hz: f32 = 261.625565;

/// pitch_cv(1.0/oct) を Hz へ変換する。Hz をグラフ全体に流さないための境界関数。
pub inline fn pitchToHz(base_hz: f32, pitch_cv: f32) f32 {
    return base_hz * @exp2(pitch_cv);
}

/// gate 値が high か。
pub inline fn gateHigh(v: f32) bool {
    return v >= gate_threshold;
}

/// モジュールの process が 1 サンプル分の入出力にアクセスするためのビュー。
/// inputs / connected / outputs はグラフが用意した一時スライス（process 内で保持しない）。
pub const Io = struct {
    /// 各入力ポートの値（未接続は 0）。長さ = 入力ポート数。
    inputs: []const f32,
    /// 各入力ポートが接続されているか（CV 未接続時に param へフォールバックする判定用）。
    connected: []const bool,
    /// 各出力ポートの書き込み先。長さ = 出力ポート数。
    outputs: []f32,
    /// 実効サンプルレート（Hz）。
    sample_rate: f32,
};

/// モジュールの vtable。process（毎サンプル・軽量）と updateParams（ブロック先頭・係数再計算）を分離する
/// （重い tan() 等を毎サンプル走らせない。§4.1）。
pub const VTable = struct {
    process: *const fn (ctx: *anyopaque, io: *Io) void,
    updateParams: *const fn (ctx: *anyopaque, sample_rate: f32) void,
};

/// updateParams を持たないモジュール用の no-op。
pub fn noopUpdate(_: *anyopaque, _: f32) void {}

/// addModule に渡すモジュール記述。ctx は具体モジュール構造体へのポインタ（caller が生存所有）。
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
