//! Null audio output device (L1 オーディオ出力プリミティブ・TASK-32.4 P4)
//!
//! headless harness（`VP_HARNESS_HEADLESS=1`）用の実デバイス無し出力。純 Zig・OS 非依存
//! （`@cImport` しない。audio_linux/audio_windows と同じ ABI 戦略）。`start()` で再生スレッド
//! (`std.Thread`) を spawn し、実時間ペーシング（period 分の時間だけ sleep）で render callback を
//! pull する（audio_linux の push-thread パターン踏襲。実デバイスと同じ「別スレッドが実時間で
//! callback を駆動する」挙動をアプリから見て変えないため。詳細はタスク plan §3.2 の「未決事項」）。
//!
//! ホットパス宣言: `renderThread` は **RT（実時間）pull ループ**。scratch は `open()` で事前確保済みで、
//! ループ内（callback 呼び出し + sleep）に **alloc/lock/IO/panic は無い**（FailingAllocator でテスト固定）。
//! null デバイス自身は毎サンプルの演算を持たない（サンプル生成は呼び出し側のユーザー callback）。
//!
//! ## 公開型は呼び出し元（OS backend）のものをそのまま使う
//!
//! `NullBackend(comptime B: type)` は `B.{Error,Config,EffectiveConfig,RenderCallback}` を
//! **エイリアスとして再エクスポート**する（新しい型を作らない）。`audio.zig` facade はこれを
//! `B = backend`（実行中 OS の backend module）で 1 回だけ instantiate するため、
//! `NullBackend(backend).Config` は `backend.Config` と文字通り同一の型になり、
//! facade の公開 `Config`/`Error`/... は一切変更不要（型もエラーセットも増えない）。

const std = @import("std");

pub fn NullBackend(comptime B: type) type {
    return struct {
        pub const Error = B.Error;
        pub const Config = B.Config;
        pub const EffectiveConfig = B.EffectiveConfig;
        pub const RenderCallback = B.RenderCallback;

        /// 再生スレッド / callback に安定アドレスで渡すための状態。`open()` で heap 確保し
        /// `close()` で破棄する（backend 実装と同じ形）。
        const State = struct {
            render_callback: RenderCallback,
            userdata: ?*anyopaque,
            effective: EffectiveConfig,
            running: std.atomic.Value(bool),
            thread: ?std.Thread,
            scratch: []f32, // period * channels の interleaved バッファ（open 時のみ確保）
            allocator: std.mem.Allocator,
        };

        pub const AudioDevice = struct {
            state: *State,

            pub fn config(self: @This()) EffectiveConfig {
                return self.state.effective;
            }

            /// 再生スレッドを起動する。実デバイスの prepare に相当する処理は無いので常に成功する
            /// （spawn 失敗のみ `error.StartFailed`）。
            pub fn start(self: @This()) Error!void {
                const state = self.state;
                if (state.thread != null) return; // 二重 start は無視（backend と同じ契約）
                state.running.store(true, .release);
                state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
                    state.running.store(false, .release);
                    return error.StartFailed;
                };
            }

            /// 再生スレッドを止める。`running=false` → join。
            pub fn stop(self: @This()) void {
                const state = self.state;
                if (state.thread) |thread| {
                    state.running.store(false, .release);
                    thread.join();
                    state.thread = null;
                }
            }

            /// stop → scratch 解放 → State 破棄。
            pub fn close(self: @This()) void {
                const state = self.state;
                self.stop();
                state.allocator.free(state.scratch);
                state.allocator.destroy(state);
            }
        };

        /// RT 契約区間: `render_callback` 呼び出し + sleep のみ。alloc/lock/IO/panic 禁止。
        fn renderThread(state: *State) void {
            const ch: usize = state.effective.channels;
            const period: usize = state.effective.max_frames_per_slice;
            const sample_rate = state.effective.sample_rate;
            const period_ns = periodNanos(period, sample_rate);

            while (state.running.load(.acquire)) {
                state.render_callback(
                    state.scratch,
                    @intCast(period),
                    @intCast(ch),
                    sample_rate,
                    state.userdata,
                );
                // 実デバイス同型の実時間ペーシング（1 period 分の再生時間だけ待つ）。
                sleepNs(period_ns);
            }
        }

        pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
            const effective = EffectiveConfig{
                .sample_rate = cfg.sample_rate,
                .channels = cfg.channels,
                .max_frames_per_slice = cfg.buffer_frames,
            };

            const state = allocator.create(State) catch return error.OpenFailed;
            errdefer allocator.destroy(state);

            const scratch = allocator.alloc(f32, @as(usize, effective.max_frames_per_slice) * effective.channels) catch
                return error.OpenFailed;
            errdefer allocator.free(scratch);

            state.* = .{
                .render_callback = cfg.render_callback,
                .userdata = cfg.userdata,
                .effective = effective,
                .running = std.atomic.Value(bool).init(false),
                .thread = null,
                .scratch = scratch,
                .allocator = allocator,
            };

            return .{ .state = state };
        }
    };
}

/// period（frames）と sample_rate から period の再生時間をナノ秒で求める（純ロジック・テスト可能）。
fn periodNanos(period: usize, sample_rate: u32) u64 {
    if (sample_rate == 0) return 0;
    return @as(u64, period) * std.time.ns_per_s / sample_rate;
}

// ============================================================================
// OS 非依存 sleep（`src/platform.zig` の `sleep()` と同じ実装。audio 層は platform に依存しない
// レイヤー設計のため import せず同じパターンをここに複製する。POSIX=nanosleep / Windows=Sleep）。
// ============================================================================
const builtin = @import("builtin");

const win_sleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
} else struct {};

fn sleepNs(nanoseconds: u64) void {
    if (builtin.os.tag == .windows) {
        win_sleep.Sleep(@intCast(nanoseconds / 1_000_000));
    } else {
        var req = std.c.timespec{
            .sec = @intCast(nanoseconds / 1_000_000_000),
            .nsec = @intCast(nanoseconds % 1_000_000_000),
        };
        _ = std.c.nanosleep(&req, null);
    }
}

// ============================================================================
// tests（display/実デバイス不要・OS 非依存）
// ============================================================================
const testing = std.testing;

/// テスト専用の backend 型集合（audio_{macos,linux,windows}.zig と同一シグネチャ）。
const TestBackend = struct {
    pub const Error = error{
        OpenFailed,
        NoDevice,
        ConfigFailed,
        InitializeFailed,
        QueryFailed,
        StartFailed,
    };
    pub const RenderCallback = *const fn (buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void;
    pub const Config = struct {
        sample_rate: u32 = 48000,
        buffer_frames: u32 = 512,
        channels: u32 = 2,
        render_callback: RenderCallback,
        userdata: ?*anyopaque = null,
    };
    pub const EffectiveConfig = struct {
        sample_rate: u32,
        channels: u32,
        max_frames_per_slice: u32,
    };
};
const TestNull = NullBackend(TestBackend);

test "periodNanos: sample_rate=0 は 0、そうでなければ period/sample_rate 秒" {
    try testing.expectEqual(@as(u64, 0), periodNanos(512, 0));
    try testing.expectEqual(@as(u64, std.time.ns_per_s), periodNanos(48000, 48000));
    try testing.expectEqual(@as(u64, std.time.ns_per_s / 2), periodNanos(24000, 48000));
}

const CallCtx = struct {
    count: std.atomic.Value(u32) = .init(0),
    last_frames: std.atomic.Value(u32) = .init(0),
};

fn countingCallback(buf: []f32, frames: u32, channels: u32, sample_rate: u32, userdata: ?*anyopaque) void {
    _ = sample_rate;
    const ctx: *CallCtx = @ptrCast(@alignCast(userdata.?));
    @memset(buf[0 .. @as(usize, frames) * channels], 0.5);
    ctx.last_frames.store(frames, .monotonic);
    _ = ctx.count.fetchAdd(1, .monotonic);
}

test "open/start/stop/close: callback が実時間で複数回呼ばれ、join が安全に終わる" {
    var ctx = CallCtx{};
    const device = try TestNull.open(testing.allocator, .{
        .sample_rate = 48000,
        .buffer_frames = 128, // 短い period で速く複数回まわす（≈2.7ms/回）
        .channels = 2,
        .render_callback = countingCallback,
        .userdata = &ctx,
    });
    defer device.close();

    try testing.expectEqual(@as(u32, 48000), device.config().sample_rate);
    try testing.expectEqual(@as(u32, 128), device.config().max_frames_per_slice);

    try device.start();
    sleepNs(30 * std.time.ns_per_ms); // 30ms あれば数回まわる
    device.stop();

    try testing.expect(ctx.count.load(.monotonic) >= 2);
    try testing.expectEqual(@as(u32, 128), ctx.last_frames.load(.monotonic));

    // 二重 stop / start は安全（no-op）
    device.stop();
}

test "RT 契約: pull ループ稼働中は open 後の追加アロケーションが無い（FailingAllocator）" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();

    var ctx = CallCtx{};
    const device = try TestNull.open(alloc, .{
        .sample_rate = 48000,
        .buffer_frames = 64,
        .channels = 1,
        .render_callback = countingCallback,
        .userdata = &ctx,
    });
    defer device.close();

    const allocs_after_open = failing.allocations;
    // ここから先で 1 回でも alloc されたら OOM になるよう固定する。
    failing.fail_index = allocs_after_open;

    try device.start();
    sleepNs(30 * std.time.ns_per_ms);
    device.stop();

    try testing.expectEqual(allocs_after_open, failing.allocations); // pull ループ中に alloc 無し
    try testing.expect(ctx.count.load(.monotonic) >= 1); // callback は実際に呼ばれている
}
