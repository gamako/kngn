//! ワウ・フラッター: 可変ディレイ＋低速 LFO でテープのピッチ揺れを作る（lofi の質感）。
//! feedback なし（発散経路を作らない）。RT 安全（DelayLine 固定確保・確保/ロックなし）。

const std = @import("std");
const DelayLine = @import("delay.zig").DelayLine;
const Lfo = @import("lfo.zig").Lfo;

const cap = 8192;

pub const WowFlutter = struct {
    line: DelayLine(cap) = .{},
    wow_lfo: Lfo = .{ .waveform = .sine },
    flutter_lfo: Lfo = .{ .waveform = .triangle },
    base_delay_ms: f32 = 8.0,
    wow_depth_ms: f32 = 2.5,
    flutter_depth_ms: f32 = 0.35,
    wow_rate_hz: f32 = 0.35,
    flutter_rate_hz: f32 = 6.0,
    wet: f32 = 0.35,

    /// 1 サンプル処理（sr 必須）。
    pub fn process(self: *WowFlutter, x: f32, sr: f32) f32 {
        const in = if (std.math.isFinite(x)) x else 0.0;
        const wow = self.wow_lfo.next(self.wow_rate_hz, sr);
        const flutter = self.flutter_lfo.next(self.flutter_rate_hz, sr);
        const delay_ms = self.base_delay_ms + wow * self.wow_depth_ms + flutter * self.flutter_depth_ms;
        const delay_samples = std.math.clamp(delay_ms * sr / 1000.0, 1.0, @as(f32, cap - 1));
        const y = self.line.readAt(delay_samples);
        self.line.write(in);
        const w = std.math.clamp(self.wet, 0.0, 1.0);
        const out = in * (1.0 - w) + y * w;
        return if (std.math.isFinite(out)) out else 0.0;
    }
};

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "WowFlutter: wet=0 passes input through" {
    var wf = WowFlutter{ .wet = 0.0 };
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const x = @sin(@as(f32, @floatFromInt(i)) * 0.2);
        try testing.expectApproxEqAbs(x, wf.process(x, 48000), 1e-6);
    }
}

test "WowFlutter: delays signal (impulse comes out later)" {
    var wf = WowFlutter{ .wet = 1.0, .base_delay_ms = 4.0, .wow_depth_ms = 0, .flutter_depth_ms = 0 };
    const sr: f32 = 48000;
    const out_first = wf.process(1.0, sr); // impulse in
    var max_after: f32 = 0;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const y = wf.process(0.0, sr);
        max_after = @max(max_after, @abs(y));
    }
    try testing.expect(@abs(out_first) < 0.5); // 即座には出ない（遅延）
    try testing.expect(max_after > 0.5); // 後で出てくる
}

test "WowFlutter: deterministic and finite/bounded over long run" {
    var a = WowFlutter{};
    var b = WowFlutter{};
    const sr: f32 = 48000;
    var peak: f32 = 0;
    var i: u32 = 0;
    while (i < 100000) : (i += 1) {
        const x = @sin(@as(f32, @floatFromInt(i)) * 0.05) * 0.5;
        const ya = a.process(x, sr);
        const yb = b.process(x, sr);
        try testing.expectEqual(ya, yb);
        try testing.expect(std.math.isFinite(ya));
        peak = @max(peak, @abs(ya));
    }
    try testing.expect(peak < 1.5);
}
