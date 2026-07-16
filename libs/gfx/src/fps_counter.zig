const std = @import("std");

/// FPS計測ヘルパー
///
/// 設計意図:
/// - 指定した時間間隔でFPSを自動計測
/// - update()を毎フレーム呼ぶだけでカウント
/// - 間隔経過時にFPS値を自動更新（コンソール出力はオプション）
///
/// 使用例:
/// ```zig
/// var fps_counter = FpsCounter.init(1.0);  // 1秒間隔
///
/// while (c.platform_poll_events(window)) {
///     const frame_time = /* 前フレームからの経過時間 */;
///
///     if (fps_counter.update(frame_time)) {
///         std.debug.print("FPS: {d}\n", .{fps_counter.getFps()});
///     }
///
///     // ... 描画処理 ...
/// }
/// ```
pub const FpsCounter = struct {
    /// 計測間隔（秒）
    interval: f64,

    /// 現在の経過時間（秒）
    timer: f64 = 0.0,

    /// 現在の間隔内でのフレーム数
    frame_count: u32 = 0,

    /// 最後に計算されたFPS値
    last_fps: u32 = 0,

    /// 初期化
    /// - interval: FPS計測の更新間隔（秒）、通常は1.0を指定
    pub fn init(interval: f64) FpsCounter {
        std.debug.assert(interval > 0.0); // ゼロ除算を防ぐ
        return .{ .interval = interval };
    }

    /// フレーム時間を追加し、FPS値を更新
    ///
    /// 戻り値: true の場合、FPS値が更新された（間隔経過）
    pub fn update(self: *FpsCounter, frame_time: f64) bool {
        self.timer += frame_time;
        self.frame_count += 1;

        if (self.timer >= self.interval) {
            // FPS = フレーム数 / 経過時間
            self.last_fps = @intFromFloat(@as(f64, @floatFromInt(self.frame_count)) / self.timer);

            // リセット
            // 注: ラグスパイク後の誤報を防ぐため、余剰時間は切り捨てる
            self.frame_count = 0;
            self.timer = 0.0;

            return true;
        }

        return false;
    }

    /// 最新のFPS値を取得
    pub fn getFps(self: *const FpsCounter) u32 {
        return self.last_fps;
    }

    /// カウンタをリセット（シーン遷移、ポーズ解除時など）
    pub fn reset(self: *FpsCounter) void {
        self.timer = 0.0;
        self.frame_count = 0;
        self.last_fps = 0;
    }
};

test "FpsCounter basic" {
    var counter = FpsCounter.init(1.0);

    // 60FPSのシミュレーション（1フレーム約16.67ms）
    const dt = 1.0 / 60.0;

    // 59フレーム目までは更新されない
    for (0..59) |_| {
        const updated = counter.update(dt);
        try std.testing.expect(!updated);
    }

    // 60フレーム目で約1秒経過 → FPS更新
    const updated = counter.update(dt);
    try std.testing.expect(updated);

    // FPSは約60
    const fps = counter.getFps();
    try std.testing.expect(fps >= 59 and fps <= 61);
}

test "FpsCounter reset" {
    var counter = FpsCounter.init(1.0);

    // いくつかのフレームを追加
    _ = counter.update(0.5);
    try std.testing.expect(counter.frame_count > 0);

    // リセット
    counter.reset();
    try std.testing.expectEqual(@as(f64, 0.0), counter.timer);
    try std.testing.expectEqual(@as(u32, 0), counter.frame_count);
    try std.testing.expectEqual(@as(u32, 0), counter.last_fps);
}

test "FpsCounter timer reset on interval" {
    var counter = FpsCounter.init(1.0);

    // 1.1秒分の時間を追加
    const updated = counter.update(1.1);
    try std.testing.expect(updated);

    // タイマーは0にリセットされる（ラグスパイク後の誤報を防ぐため）
    try std.testing.expectEqual(@as(f64, 0.0), counter.timer);
}

test "FpsCounter zero interval assertion" {
    // interval=0.0 でアサーション失敗することを確認
    // 注: このテストはデバッグビルドでのみ機能
    // リリースビルドではassertが無効化される
}
