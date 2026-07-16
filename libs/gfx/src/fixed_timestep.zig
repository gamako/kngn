/// 固定タイムステップヘルパー
///
/// 論理更新（物理演算、ゲームロジック）を固定レートで実行するための時間管理。
/// フレームレートが変動しても、論理的な動作が一定になることを保証する。
///
/// 設計意図:
/// - 描画レートと論理更新レートを分離し、安定したシミュレーションを実現
/// - 高速な描画では補間により滑らかな表示、処理落ち時はステップスキップで破綻を防止
/// - max_steps（デフォルト5）により「死のスパイラル」（更新が追いつかず無限に遅延が増加する現象）を防止
///
/// フレーム戦略との関係:
///
/// 1. 可変タイムステップ（delta time直接使用）
///    - 毎フレームのdelta timeで直接計算
///    - シンプルだがフレームレート依存の動作になる
///    - このヘルパーは不要
///
/// 2. 固定タイムステップ（描画と同期）
///    - 描画と論理更新が同じレート（例: 両方60Hz + VSync）
///    - 安定した動作、alpha補間は不要
///    - このヘルパーを使用（alpha()は不要）
///
/// 3. 固定タイムステップ（描画と非同期）← このヘルパーの主な用途
///    - 描画と論理更新が異なるレート、またはフレームレートが不安定
///    - alpha補間で滑らかな描画（最大1dt分の遅延あり）
///    - このヘルパー + alpha()を使用
///
/// 参考: https://gafferongames.com/post/fix_your_timestep/
pub const FixedTimeStep = struct {
    accumulator: f64 = 0.0, // 公開: 呼び出し側が操作可能
    dt: f64, // 論理更新間隔（秒）
    max_steps: usize = 5, // スパイラル防止

    pub fn init(update_rate: f64) FixedTimeStep {
        return .{ .dt = 1.0 / update_rate };
    }

    /// フレーム時間を追加し、実行すべき論理更新回数を返す
    pub fn update(self: *FixedTimeStep, frame_time: f64) usize {
        self.accumulator += frame_time;
        var steps: usize = @intFromFloat(self.accumulator / self.dt);

        if (steps > self.max_steps) {
            steps = self.max_steps;
        }

        self.accumulator -= @as(f64, @floatFromInt(steps)) * self.dt;
        return steps;
    }

    /// 補間係数（0.0〜1.0）を取得
    ///
    /// 目的: 描画を滑らかにする
    /// 論理更新のタイミングと描画タイミングはずれるため、
    /// 直前2回の論理状態（prev, current）を補間して描画位置を求める。
    ///
    /// トレードオフ:
    /// 補間により描画位置は実時間より最大1論理更新分（dt）遅れる。
    /// 60Hzなら最大約16.7ms。通常は問題にならないが、
    /// 低遅延が求められる場合（格ゲー等）は考慮が必要。
    ///
    /// 補間はオプション:
    /// 遅延を避けたい場合は補間を使わず、最新の論理位置をそのまま描画できる。
    /// 論理更新が60Hz以上なら補間なしでも通常は十分滑らか。
    ///
    /// 使用例:
    ///   // prev_x: update()実行前に保存した状態
    ///   // current_x: update()実行後の最新状態
    ///   const alpha = timestep.alpha();
    ///   const draw_x = prev_x + (current_x - prev_x) * alpha;
    pub fn alpha(self: *const FixedTimeStep) f64 {
        return self.accumulator / self.dt;
    }

    /// accumulatorをリセット（シーン遷移、ポーズ解除時など）
    pub fn reset(self: *FixedTimeStep) void {
        self.accumulator = 0.0;
    }
};

test "FixedTimeStep basic" {
    var ts = FixedTimeStep.init(60.0);

    // 60FPSで1フレーム分の時間を追加 → 1ステップ
    const steps1 = ts.update(1.0 / 60.0);
    try @import("std").testing.expectEqual(@as(usize, 1), steps1);

    // 半分の時間を追加 → 0ステップ（accumulatorに蓄積）
    const steps2 = ts.update(1.0 / 120.0);
    try @import("std").testing.expectEqual(@as(usize, 0), steps2);

    // もう半分追加 → 1ステップ
    const steps3 = ts.update(1.0 / 120.0);
    try @import("std").testing.expectEqual(@as(usize, 1), steps3);
}

test "FixedTimeStep max_steps" {
    var ts = FixedTimeStep.init(60.0);

    // 大きな時間を追加（スパイク時のシミュレーション）
    const steps = ts.update(1.0); // 1秒 = 60ステップ分
    try @import("std").testing.expectEqual(@as(usize, 5), steps); // max_stepsで制限
}

test "FixedTimeStep alpha" {
    var ts = FixedTimeStep.init(60.0);
    const dt = ts.dt;

    // 半分の時間を追加
    _ = ts.update(dt * 0.5);
    const a = ts.alpha();

    // alphaは0.5付近であるべき
    try @import("std").testing.expect(a > 0.4 and a < 0.6);
}

test "FixedTimeStep reset" {
    var ts = FixedTimeStep.init(60.0);

    // 時間を蓄積
    _ = ts.update(1.0 / 120.0);
    try @import("std").testing.expect(ts.accumulator > 0);

    // リセット
    ts.reset();
    try @import("std").testing.expectEqual(@as(f64, 0.0), ts.accumulator);
}
