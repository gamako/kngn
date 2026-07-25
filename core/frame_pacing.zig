//! フレーム pacing の純ロジック（TASK-176）。OS / display / platform 非依存で単体テストできる。
//!
//! **ホットパス宣言: フレーム毎（1 フレームに 1 回）**。全画素ループ・RT（毎サンプル）経路ではない。
//! 追加コストは f64 演算数回と時計読み 2-3 回で、フレーム予算（ms 級）に対し無視できる。
//!
//! ## なぜ「固定 sleep」ではなく deadline + 補正なのか（実測。2026-07-25 / Apple Silicon / ReleaseFast）
//!
//! 目標周期 16.667ms・300 反復での平均 overshoot と実効 fps:
//!
//! | 手法 | 平均 overshoot | 実効 fps |
//! |---|---|---|
//! | `nanosleep`（相対） | 3.40ms | 49.8 |
//! | `mach_wait_until`（絶対時刻） | 3.45ms | 49.7 |
//! | 絶対時刻 + 最後 1.5ms busy-wait | 1.69ms | 54.5 |
//! | **overshoot EWMA 補正（busy-wait なし）** | **-0.10ms** | **60.4** |
//!
//! macOS の overshoot は要求時間の約 20%（timer slack）に比例し、**絶対時刻 sleep では解消しない**。
//! そこで「実測 overshoot を EWMA で学習し、要求から差し引く」方式を採る（busy-wait は使わない。
//! 常時 spin は平均誤差を +0.6ms 側にずらし fps を落とす）。
//!
//! caller（`core/platform.zig`）は `Driver(clock, sleeper)` に時計と sleep を comptime で注入する。
//! テストは偽の時計/sleep を注入して、sleep 要求値・呼び出し回数・学習状態を直接 assert する。

const std = @import("std");

/// 早めに起きるための固定マージン（学習誤差の吸収分）。
pub const MARGIN_NS: u64 = 200_000; // 200µs
/// overshoot 推定の上限。1 度の巨大 oversleep で推定が壊れ pacing が永久停止するのを防ぐ。
pub const MAX_EST_NS: u64 = 4_000_000; // 4ms
/// これを超える残り時間は「時計飛び / スリープ復帰」と判断して学習をリセットする。
pub const MAX_REMAINING_S: f64 = 1.0;
/// EWMA の重み（1/8）。
const EWMA_SHIFT: u6 = 3;

/// pacing 判断の結果。実行（sleep）は Driver が行う。
pub const Decision = union(enum) {
    /// 待たない（deadline 到達済み / 非有限入力）
    no_wait,
    /// 学習状態を初期化して待たない（時計飛び・スリープ復帰を検出）
    reset,
    /// この ns だけ sleep を要求する（0 は「sleep しないが学習は減衰させる」）
    sleep: u64,
};

/// 要求 sleep 時間 = remaining - (推定 overshoot + margin)。下限 0。
pub fn requestNs(remaining_ns: u64, est_ns: u64, margin_ns: u64) u64 {
    const deduct = est_ns +| margin_ns;
    if (remaining_ns <= deduct) return 0;
    return remaining_ns - deduct;
}

/// overshoot 推定の EWMA 更新。
/// - overshoot は `actual - request`（逆向きではない）。負値（早起き）は 0 として扱う。
/// - `request == 0`（sleep しなかったフレーム）は観測が無いので **推定を半減**して必ず回復させる。
/// - 上限 `MAX_EST_NS` でクランプする（異常値で pacing が永久停止しないための安全策）。
pub fn updateEwma(prev_ns: u64, request_ns: u64, actual_ns: u64) u64 {
    if (request_ns == 0) return prev_ns / 2;
    const observed: u64 = if (actual_ns > request_ns) actual_ns - request_ns else 0;
    const clamped = @min(observed, MAX_EST_NS);
    const next = if (clamped >= prev_ns)
        prev_ns + ((clamped - prev_ns) >> EWMA_SHIFT)
    else
        prev_ns - ((prev_ns - clamped) >> EWMA_SHIFT);
    return @min(next, MAX_EST_NS);
}

/// pacing の判断（入力ガードもここに集約する。実装が迂回できない単一窓口）。
/// deadline/now は単調時計の秒。**f64 のまま検査してから ns 化**する
/// （先に整数化すると Inf / 巨大値で trap する）。
pub fn decide(deadline_s: f64, now_s: f64, est_ns: u64) Decision {
    if (!std.math.isFinite(deadline_s) or !std.math.isFinite(now_s)) return .no_wait;
    const remaining_s = deadline_s - now_s;
    if (!(remaining_s > 0)) return .no_wait; // NaN 混入でも false になる
    if (remaining_s > MAX_REMAINING_S) return .reset;
    const remaining_ns: u64 = @intFromFloat(remaining_s * 1_000_000_000.0);
    return .{ .sleep = requestNs(remaining_ns, est_ns, MARGIN_NS) };
}

/// 学習状態（main thread 専有。RT スレッドからは触らない）。
pub const Pacer = struct {
    est_overshoot_ns: u64 = 0,

    pub fn reset(self: *Pacer) void {
        self.est_overshoot_ns = 0;
    }
};

/// 時計（秒を返す）と sleep（ns 要求）を comptime 注入した pacing 実行器。
/// 間接呼び出しを作らないため comptime パラメータにしている。
pub fn Driver(comptime clock: fn () f64, comptime sleeper: fn (u64) void) type {
    return struct {
        /// `deadline_s` に向けて best-effort で待つ。`manual_clock=true`（harness の replay 等）では
        /// **完全 no-op**（時計も読まず学習状態も触らない）。
        pub fn pace(pacer: *Pacer, deadline_s: f64, manual_clock: bool) void {
            if (manual_clock) return;
            const before = clock();
            switch (decide(deadline_s, before, pacer.est_overshoot_ns)) {
                .no_wait => {},
                .reset => pacer.reset(),
                .sleep => |request_ns| {
                    if (request_ns == 0) {
                        // sleep しないフレームでも推定を減衰させる（回復経路）。
                        pacer.est_overshoot_ns = updateEwma(pacer.est_overshoot_ns, 0, 0);
                        return;
                    }
                    // 実 sleep 時間は **sleep 直前・直後**の差で測る（判断や学習更新のコストを混ぜない）。
                    const t0 = clock();
                    sleeper(request_ns);
                    const t1 = clock();
                    const actual_ns: u64 = if (t1 > t0)
                        @intFromFloat(@min((t1 - t0) * 1_000_000_000.0, 1e12))
                    else
                        0;
                    pacer.est_overshoot_ns = updateEwma(pacer.est_overshoot_ns, request_ns, actual_ns);
                },
            }
        }
    };
}

// ============================================================================
// tests（display / OS 非依存。偽の時計と sleep を注入して挙動を固定する）
// ============================================================================

test "requestNs は remaining から est+margin を引く（下限 0・overflow しない）" {
    try std.testing.expectEqual(@as(u64, 13_466_666), requestNs(16_666_666, 3_000_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), requestNs(3_200_000, 3_000_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), requestNs(1_000_000, 3_000_000, 200_000));
    try std.testing.expectEqual(@as(u64, 0), requestNs(0, 0, 200_000));
    // 飽和加算で overflow しない
    try std.testing.expectEqual(@as(u64, 0), requestNs(std.math.maxInt(u64) - 1, std.math.maxInt(u64), 200_000));
}

test "updateEwma は overshoot=actual-request を学習し早起きは 0 扱い" {
    // 計算方向: actual > request の差分が overshoot（request - actual ではない）
    try std.testing.expectEqual(@as(u64, 375_000), updateEwma(0, 10_000_000, 13_000_000));
    // 早起き（actual < request）は observed=0 → prev から 1/8 下がる
    try std.testing.expectEqual(@as(u64, 875_000), updateEwma(1_000_000, 10_000_000, 9_000_000));
    // 一定 overshoot を与え続けると当該値へ漸近する
    var est: u64 = 0;
    for (0..200) |_| est = updateEwma(est, 10_000_000, 13_000_000);
    try std.testing.expect(est > 2_900_000 and est <= 3_000_000);
}

test "updateEwma は上限クランプし request==0 で必ず回復する（永久停止しない）" {
    // 1 秒 oversleep 相当の異常値でも上限 4ms を超えない
    try std.testing.expect(updateEwma(0, 10_000_000, 1_010_000_000) <= MAX_EST_NS);
    // 上限に張り付いた状態から sleep しないフレームが続けば半減で回復する
    var est: u64 = MAX_EST_NS;
    var frames: u32 = 0;
    while (est > MARGIN_NS and frames < 32) : (frames += 1) est = updateEwma(est, 0, 0);
    try std.testing.expect(frames <= 6); // 4ms → 200µs は半減 5 回
    // 回復後は 16.67ms の残りに対して再び十分な sleep 要求が出る
    try std.testing.expect(requestNs(16_666_666, est, MARGIN_NS) > 15_000_000);
}

test "decide の入力ガード（非有限・過去 deadline・時計飛び）" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(Decision.no_wait, decide(nan, 100.0, 0));
    try std.testing.expectEqual(Decision.no_wait, decide(100.0, nan, 0));
    try std.testing.expectEqual(Decision.no_wait, decide(inf, 100.0, 0)); // 非有限は remaining>1s より優先
    try std.testing.expectEqual(Decision.no_wait, decide(-inf, 100.0, 0));
    try std.testing.expectEqual(Decision.no_wait, decide(100.0, 100.0, 0)); // 同時刻
    try std.testing.expectEqual(Decision.no_wait, decide(99.9, 100.0, 0)); // 過去
    try std.testing.expectEqual(Decision.reset, decide(101.5, 100.0, 0)); // 1 秒超 = 時計飛び
    switch (decide(100.016_666_666, 100.0, 0)) { // 通常
        .sleep => |ns| try std.testing.expect(ns > 16_000_000 and ns < 16_666_666),
        else => return error.TestUnexpectedResult,
    }
    switch (decide(100.001, 100.0, 4_000_000)) { // 推定が残りを食い切る
        .sleep => |ns| try std.testing.expectEqual(@as(u64, 0), ns),
        else => return error.TestUnexpectedResult,
    }
}

/// テスト用の偽時計・偽 sleep。`sleeper` は「要求 ns に overshoot_ns を足した時間だけ経過した」ことにする。
const Fake = struct {
    var now_s: f64 = 100.0;
    var overshoot_ns: u64 = 0;
    var sleep_calls: u32 = 0;
    var last_request_ns: u64 = 0;

    fn clock() f64 {
        return now_s;
    }
    fn sleeper(ns: u64) void {
        sleep_calls += 1;
        last_request_ns = ns;
        now_s += @as(f64, @floatFromInt(ns + overshoot_ns)) / 1e9;
    }
    fn reset(overshoot: u64) void {
        now_s = 100.0;
        overshoot_ns = overshoot;
        sleep_calls = 0;
        last_request_ns = 0;
    }
};
const FakeDriver = Driver(Fake.clock, Fake.sleeper);

test "Driver: manual clock では sleep も学習更新も起きない" {
    Fake.reset(0);
    var pacer: Pacer = .{ .est_overshoot_ns = 1_234_567 };
    FakeDriver.pace(&pacer, Fake.now_s + 10.0, true); // 遠い未来でも no-op
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
    try std.testing.expectEqual(@as(f64, 100.0), Fake.now_s); // 時計も読まない（進めない）
    try std.testing.expectEqual(@as(u64, 1_234_567), pacer.est_overshoot_ns);
}

test "Driver: deadline 過去・時計飛びでは sleep しない（reset は学習を初期化）" {
    Fake.reset(0);
    var pacer: Pacer = .{ .est_overshoot_ns = 3_000_000 };
    FakeDriver.pace(&pacer, Fake.now_s - 0.01, false); // 過去
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
    try std.testing.expectEqual(@as(u64, 3_000_000), pacer.est_overshoot_ns); // no_wait は学習を触らない

    FakeDriver.pace(&pacer, Fake.now_s + 5.0, false); // 1 秒超 = 時計飛び
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
    try std.testing.expectEqual(@as(u64, 0), pacer.est_overshoot_ns); // reset
}

test "Driver: 20% timer slack の環境で平均周期が目標へ収束する（実測の再現）" {
    // 実機と同じ性質（要求時間の 20% 超過）を偽 sleep で再現し、60fps 目標に収束することを固定する。
    const period_s: f64 = 1.0 / 60.0;
    Fake.reset(0);
    var pacer: Pacer = .{};
    // slack は「要求の 20%」なので固定値では表せない → sleeper 呼び出しごとに更新する
    var last_period_err_ns: i64 = 0;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        const t0 = Fake.now_s;
        // 次フレームの overshoot を「前回要求の 20%」として設定（要求に比例する slack）
        Fake.overshoot_ns = @intFromFloat(@as(f64, @floatFromInt(@max(Fake.last_request_ns, 1))) * 0.20);
        FakeDriver.pace(&pacer, t0 + period_s, false);
        last_period_err_ns = @as(i64, @intFromFloat((Fake.now_s - t0) * 1e9)) - @as(i64, @intFromFloat(period_s * 1e9));
    }
    // 収束後の 1 フレーム誤差が ±0.5ms 以内（= 実効 59-61fps 相当）
    try std.testing.expect(last_period_err_ns > -500_000 and last_period_err_ns < 500_000);
    // 学習値が slack 相当（要求 ≒ 13ms の 20% ≒ 2.6ms）に収まっている
    try std.testing.expect(pacer.est_overshoot_ns > 1_500_000 and pacer.est_overshoot_ns <= MAX_EST_NS);
    // busy-wait をしない設計なので sleep 呼び出しは 1 フレーム 1 回以下
    try std.testing.expect(Fake.sleep_calls <= 300);
}

test "Driver: request==0 のフレームでも学習が減衰する（Driver 経路）" {
    Fake.reset(0);
    // est が残りを食い切る状況（残り 1ms・est 4ms）を作ると decide は sleep 0 を返す。
    var pacer: Pacer = .{ .est_overshoot_ns = MAX_EST_NS };
    FakeDriver.pace(&pacer, Fake.now_s + 0.001, false);
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls); // OS sleep は呼ばない
    try std.testing.expectEqual(MAX_EST_NS / 2, pacer.est_overshoot_ns); // が、学習は半減する
    // 繰り返せば必ず下がり続ける（永久停止しない）
    const before = pacer.est_overshoot_ns;
    FakeDriver.pace(&pacer, Fake.now_s + 0.001, false);
    try std.testing.expect(pacer.est_overshoot_ns < before);
    try std.testing.expectEqual(@as(u32, 0), Fake.sleep_calls);
}

test "Driver: 巨大 oversleep 後も数フレームで pacing が復活する" {
    const period_s: f64 = 1.0 / 60.0;
    Fake.reset(1_000_000_000); // 1 秒 oversleep する病的な sleep
    var pacer: Pacer = .{};
    FakeDriver.pace(&pacer, Fake.now_s + period_s, false);
    try std.testing.expect(pacer.est_overshoot_ns <= MAX_EST_NS);

    // 以降は正常な sleep に戻す。est が残りを食い切る間は sleep 0（=学習減衰）で、やがて sleep が復活する。
    Fake.overshoot_ns = 0;
    var recovered = false;
    var frames: u32 = 0;
    while (frames < 16) : (frames += 1) {
        const calls_before = Fake.sleep_calls;
        FakeDriver.pace(&pacer, Fake.now_s + period_s, false);
        if (Fake.sleep_calls > calls_before) {
            recovered = true;
            break;
        }
    }
    try std.testing.expect(recovered);
    try std.testing.expect(frames <= 6);
}
