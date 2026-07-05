//! harness 内蔵の synthetic capture source（偽 mic/camera。TASK-49.5）。
//!
//! `core/control/harness.zig` の組み込み `capture` probe / `capture video|audio ...` コマンドから
//! 呼ばれる。**camera.zig/audio.zig の実 facade 配線は本タスクのスコープ外**（TASK-49.2〜.4 の
//! OS backend 実装が同じファイルを並行して触るコンフリクトを避けるため。設計文書
//! `docs/plans/capture-foundation-plan.md` 5章が指す facade 側の書き換えは後続タスクに委ねる。
//! `camera.open()`/`audio.openCapture()` は本ファイル実装後も `error.Unsupported` を返し続ける）。
//! 依存は `capture_types`（共有 data plane 型）のみ。camera/audio 実 backend とは独立。
//!
//! - **video**: `SyntheticVideoDevice.renderFrame(tick)` が harness の仮想クロック
//!   （呼び出し側が渡す `tick`、実体は harness の `frame_index`）から決定論的な BGRA パターンを
//!   生成する**純関数**（スレッド無し。同じ `tick` なら bit 一致）。
//! - **audio**: 実 mic backend と同様に**専用スレッドが実時間で `CaptureCallback` を pull 駆動**
//!   する（`core/audio_null.zig` の `NullBackend` と同型パターン）。波形生成は位相アキュムレータ +
//!   `@sin`（`src/dsp/oscillator.zig` の `Oscillator.sine` と同じ per-sample `@sin` パターン。
//!   ADR-007 のレイヤー制約で `dsp`(lib) を `core` から import できないため、アルゴリズムのみ複製する）。
//!
//! ## ホットパス宣言
//! - `SyntheticVideoDevice.renderFrame`: **イベント時のみ**（`digest capture`/`snapshot capture` の
//!   都度呼ばれる。最大でも harness の `step` 頻度 ≒ 仮想60fps）。全画素を書くループだが、対象は
//!   harness 検証ツール専用の合成画像（既定 64x64 程度の小解像度）であり実アプリの本番描画ホット
//!   パスではないため、`libs/pixelops` の SIMD/div255/clip-hoist 3点セットは適用しない（判断根拠:
//!   AI/スクリプトが明示コマンドを叩いた時だけ発火し、実アプリの毎フレーム全画素パスと同じ頻度・
//!   面積では走らない。将来 camera.zig 配線後に高頻度化する場合は再判断が必要）。
//! - `SyntheticAudioDevice` の生成スレッド（`renderThread`）: **RT（毎サンプル）**。malloc/lock/IO/
//!   panic 禁止（`audio_null.zig` と同一契約）。毎サンプル `@sin` を呼ぶ点は性能規約「毎サンプルの
//!   超越関数（pow/tan/exp）は禁止」と字面上緊張するが、`src/dsp/oscillator.zig` の
//!   `Oscillator.sine`（実際の synth RT パスで本番採用済み）と同一パターンであり、このコードベース
//!   では `@sin`（コンパイラ組込み。tan/exp のような係数計算ではなく波形生成そのもの）は許容されて
//!   いる実績があるためそれを踏襲する。probe 用状態（`frames_generated`/`last_peak`）は atomic の
//!   みで共有し、plain global への書き込みはしない（data race を作らない）。

const std = @import("std");
const builtin = @import("builtin");
const capture_types = @import("capture_types");

// ============================================================================
// video: synthetic camera
// ============================================================================

/// 解像度の上限（harness 検証ツール用の暴走確保防止。page_allocator の確保も PNG snapshot も
/// この範囲なら実用上問題ない大きさに収まる）。
pub const MAX_VIDEO_DIM: u32 = 4096;

pub const VideoConfig = struct {
    width: u32 = 64,
    height: u32 = 64,
    frame_rate: u32 = 30,
};

pub const VideoEffectiveConfig = struct {
    width: u32,
    height: u32,
    frame_rate: u32,
    format: capture_types.PixelFormat = .bgra8,
};

pub const SyntheticVideoDevice = struct {
    pixels: []u32, // owned, width*height（open() で固定確保。フレーム毎の realloc 無し）
    width: u32,
    height: u32,
    frame_rate: u32,
    allocator: std.mem.Allocator,

    /// `tick` から決定論的な BGRA パターンを全画素へ書き込み、view を返す（純関数的: 同じ tick
    /// なら bit 一致）。8px ブロックのチェッカーが `tick` で1ブロックずつ回転する。
    pub fn renderFrame(self: *SyntheticVideoDevice, tick: u64) capture_types.VideoFrame {
        const w = self.width;
        const h = self.height;
        const tick_block: u32 = @truncate(tick);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const row = self.pixels[@as(usize, y) * w ..][0..w];
            const by = y >> 3;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const bx = x >> 3;
                const phase = (bx +% by +% tick_block) % 3;
                row[x] = switch (phase) {
                    0 => 0xFFFF3B30, // iOS red
                    1 => 0xFF34C759, // iOS green
                    else => 0xFF007AFF, // iOS blue
                };
            }
        }
        return .{
            .pixels = self.pixels,
            .width = w,
            .height = h,
            .stride = w,
            .format = .bgra8,
            .timestamp_ns = 0, // 仮想クロック駆動のため実時刻を持たない（tick=frame_index が代用）
            .frame_index = tick,
        };
    }

    pub fn config(self: *const SyntheticVideoDevice) VideoEffectiveConfig {
        return .{ .width = self.width, .height = self.height, .frame_rate = self.frame_rate };
    }

    pub fn close(self: *SyntheticVideoDevice) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// カメラを列挙する（synthetic: 常に1台の "Synthetic Camera" を返す）。
pub fn enumerateVideo(allocator: std.mem.Allocator) capture_types.CaptureError![]capture_types.DeviceInfo {
    const id = allocator.dupe(u8, "synthetic-camera-0") catch return error.OpenFailed;
    errdefer allocator.free(id);
    const name = allocator.dupe(u8, "Synthetic Camera") catch return error.OpenFailed;
    errdefer allocator.free(name);
    const devices = allocator.alloc(capture_types.DeviceInfo, 1) catch return error.OpenFailed;
    devices[0] = .{ .id = id, .name = name, .kind = .video_in, .is_default = true };
    return devices;
}

/// カメラ権限を要求する（synthetic: 常に granted）。
pub fn requestVideoPermission() capture_types.CaptureError!capture_types.PermissionState {
    return .granted;
}

/// synthetic カメラを開く。`width`/`height`/`frame_rate` が 0、または解像度が `MAX_VIDEO_DIM` を
/// 超える場合は `error.ConfigFailed`（暴走確保・巨大 PNG snapshot を防ぐ fail-fast）。
pub fn openVideo(allocator: std.mem.Allocator, cfg: VideoConfig) capture_types.CaptureError!SyntheticVideoDevice {
    if (cfg.width == 0 or cfg.height == 0 or cfg.frame_rate == 0) return error.ConfigFailed;
    if (cfg.width > MAX_VIDEO_DIM or cfg.height > MAX_VIDEO_DIM) return error.ConfigFailed;
    const n = @as(usize, cfg.width) * @as(usize, cfg.height);
    const pixels = allocator.alloc(u32, n) catch return error.OpenFailed;
    return .{ .pixels = pixels, .width = cfg.width, .height = cfg.height, .frame_rate = cfg.frame_rate, .allocator = allocator };
}

// ============================================================================
// audio: synthetic microphone
// ============================================================================

/// `capture_types.AudioInFrame` の再公開（`core/camera.zig`/`core/audio.zig` が capture_types の
/// 型を再公開しているのと対称。harness.zig が callback を定義する際に `capture_types` を別途
/// import しなくても `capture_synthetic.AudioInFrame` だけで完結できるようにする）。
pub const AudioInFrame = capture_types.AudioInFrame;

/// mic capture callback に渡される `AudioInFrame` を受け取る関数ポインタ型。**RT スレッドで
/// 呼ばれる**: malloc/lock/IO/panic をしてはならない。`capture_types` にはデータ型
/// （`AudioInFrame` 等）のみで callback/Config 型は無いため、ここで独自定義する（実 mic backend
/// `core/audio_capture_stub.zig` の `CaptureCallback` とはパラメータ型が同一named module
/// （`capture_types.AudioInFrame`）を参照するため構造的に同一シグネチャになるが、独立した型宣言
/// であり camera.zig/audio.zig への配線は無い。将来の facade 統合では型調整が必要になりうる）。
pub const CaptureCallback = *const fn (frame: AudioInFrame, userdata: ?*anyopaque) void;

pub const AudioConfig = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 1,
    frequency_hz: f32 = 440.0,
    block_frames: u32 = 480, // 10ms @ 48kHz
    capture_callback: CaptureCallback,
    userdata: ?*anyopaque = null,
};

pub const AudioEffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

/// 再生スレッド / callback に安定アドレスで渡すための状態。`open()` で heap 確保し `close()` で
/// 破棄する（`core/audio_null.zig` の `State` と同じ形）。
const AudioState = struct {
    callback: CaptureCallback,
    userdata: ?*anyopaque,
    effective: AudioEffectiveConfig,
    frequency_hz: f32,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    scratch: []f32, // block_frames*channels の interleaved バッファ（open 時のみ確保）
    allocator: std.mem.Allocator,
    // probe 用累計状態。RT スレッドが書き main スレッドが読む best-effort torn read（既存 `audio`
    // probe の `.unordered` store と同じ思想）。plain global には絶対に書かない。
    frames_generated: std.atomic.Value(u64),
    last_peak_bits: std.atomic.Value(u32), // f32 の bit 表現（peak は非負なので符号は問題にならない）
};

pub const SyntheticAudioDevice = struct {
    state: *AudioState,

    pub fn config(self: SyntheticAudioDevice) AudioEffectiveConfig {
        return self.state.effective;
    }

    /// 生成スレッドを起動する。実デバイスの prepare に相当する処理は無いので spawn 失敗のみ
    /// `error.StartFailed`（`audio_null.zig` と同じ契約。二重 start は無視）。
    pub fn start(self: SyntheticAudioDevice) capture_types.CaptureError!void {
        const state = self.state;
        if (state.thread != null) return;
        state.running.store(true, .release);
        state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
            state.running.store(false, .release);
            return error.StartFailed;
        };
    }

    /// 生成スレッドを止める（`running=false` → join。二重 stop は無視）。
    pub fn stop(self: SyntheticAudioDevice) void {
        const state = self.state;
        if (state.thread) |thread| {
            state.running.store(false, .release);
            thread.join();
            state.thread = null;
        }
    }

    /// stop → scratch 解放 → State 破棄。
    pub fn close(self: SyntheticAudioDevice) void {
        self.stop();
        self.state.allocator.free(self.state.scratch);
        self.state.allocator.destroy(self.state);
    }

    /// probe 用: 累計生成フレーム数（best-effort torn read。RT スレッドと同期しない）。
    pub fn framesGenerated(self: SyntheticAudioDevice) u64 {
        return self.state.frames_generated.load(.monotonic);
    }

    /// probe 用: 直近ブロックの peak 振幅（best-effort torn read）。
    pub fn lastPeak(self: SyntheticAudioDevice) f32 {
        return @bitCast(self.state.last_peak_bits.load(.monotonic));
    }
};

/// RT 契約区間: サンプル生成 + callback 呼び出し + sleep のみ。alloc/lock/IO/panic 禁止。
/// 位相アキュムレータ + `@sin`（`src/dsp/oscillator.zig` の `Oscillator.sine` と同一パターン）で
/// サイン波を生成する。ブロック内で複数回参照する `ch`/`period`/`sample_rate`/`phase_inc` は
/// スレッド起動時に1回 latch 済み。
fn renderThread(state: *AudioState) void {
    const ch: usize = state.effective.channels;
    const period: usize = state.effective.max_frames_per_slice;
    const sample_rate = state.effective.sample_rate;
    const period_ns = periodNanos(period, sample_rate);
    const phase_inc: f32 = state.frequency_hz / @as(f32, @floatFromInt(sample_rate));

    var phase: f32 = 0.0;
    while (state.running.load(.acquire)) {
        var i: usize = 0;
        var peak: f32 = 0;
        while (i < period) : (i += 1) {
            const sample = @sin(phase * std.math.tau) * 0.3; // 控えめな振幅
            phase += phase_inc;
            if (phase >= 1.0) phase -= 1.0;
            const a = @abs(sample);
            if (a > peak) peak = a;
            var c: usize = 0;
            while (c < ch) : (c += 1) state.scratch[i * ch + c] = sample;
        }

        state.callback(.{
            .samples = state.scratch[0 .. period * ch],
            .frames = @intCast(period),
            .channels = @intCast(ch),
            .sample_rate = sample_rate,
            .timestamp_ns = 0,
        }, state.userdata);

        _ = state.frames_generated.fetchAdd(period, .monotonic);
        state.last_peak_bits.store(@bitCast(peak), .monotonic);

        // 実デバイス同型の実時間ペーシング（1 period 分の再生時間だけ待つ）。
        sleepNs(period_ns);
    }
}

/// マイクを列挙する（synthetic: 常に1台の "Synthetic Microphone" を返す）。
pub fn enumerateAudio(allocator: std.mem.Allocator) capture_types.CaptureError![]capture_types.DeviceInfo {
    const id = allocator.dupe(u8, "synthetic-mic-0") catch return error.OpenFailed;
    errdefer allocator.free(id);
    const name = allocator.dupe(u8, "Synthetic Microphone") catch return error.OpenFailed;
    errdefer allocator.free(name);
    const devices = allocator.alloc(capture_types.DeviceInfo, 1) catch return error.OpenFailed;
    devices[0] = .{ .id = id, .name = name, .kind = .audio_in, .is_default = true };
    return devices;
}

/// マイク権限を要求する（synthetic: 常に granted）。
pub fn requestAudioPermission() capture_types.CaptureError!capture_types.PermissionState {
    return .granted;
}

/// synthetic マイクを開く。`sample_rate`/`channels`/`block_frames` のいずれかが 0 の場合は
/// `error.ConfigFailed`。
pub fn openAudio(allocator: std.mem.Allocator, cfg: AudioConfig) capture_types.CaptureError!SyntheticAudioDevice {
    if (cfg.sample_rate == 0 or cfg.channels == 0 or cfg.block_frames == 0) return error.ConfigFailed;
    const effective = AudioEffectiveConfig{
        .sample_rate = cfg.sample_rate,
        .channels = cfg.channels,
        .max_frames_per_slice = cfg.block_frames,
    };
    const state = allocator.create(AudioState) catch return error.OpenFailed;
    errdefer allocator.destroy(state);
    const scratch = allocator.alloc(f32, @as(usize, cfg.block_frames) * cfg.channels) catch return error.OpenFailed;
    state.* = .{
        .callback = cfg.capture_callback,
        .userdata = cfg.userdata,
        .effective = effective,
        .frequency_hz = cfg.frequency_hz,
        .running = .init(false),
        .thread = null,
        .scratch = scratch,
        .allocator = allocator,
        .frames_generated = .init(0),
        .last_peak_bits = .init(0),
    };
    return .{ .state = state };
}

// ============================================================================
// OS 非依存 sleep（`core/audio_null.zig` と同じ複製実装。audio 層は platform に依存しない
// レイヤー設計のため import せず同じパターンをここにも複製する。POSIX=nanosleep(要 link_libc) /
// Windows=Sleep(kernel32 直呼び。libc 不要)）。
// ============================================================================

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

/// period（frames）と sample_rate から period の再生時間をナノ秒で求める（純ロジック・テスト可能）。
fn periodNanos(period: usize, sample_rate: u32) u64 {
    if (sample_rate == 0) return 0;
    return @as(u64, period) * std.time.ns_per_s / sample_rate;
}

// ============================================================================
// tests（display/実デバイス不要・OS 非依存）
// ============================================================================
const testing = std.testing;

// --- video ---

test "enumerateVideo/freeDeviceList: allocator 契約どおり確保・解放できる（リーク検出）" {
    const allocator = testing.allocator;
    const devices = try enumerateVideo(allocator);
    try testing.expectEqual(@as(usize, 1), devices.len);
    try testing.expectEqualStrings("Synthetic Camera", devices[0].name);
    try testing.expectEqual(capture_types.DeviceKind.video_in, devices[0].kind);
    try testing.expect(devices[0].is_default);
    capture_types.freeDeviceList(allocator, devices);
}

test "requestVideoPermission: 常に granted" {
    try testing.expectEqual(capture_types.PermissionState.granted, try requestVideoPermission());
}

test "openVideo: width/height/frame_rate=0 は ConfigFailed" {
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = 0, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = 8, .height = 0, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = 8, .height = 8, .frame_rate = 0 }));
}

test "openVideo: 解像度上限超過は ConfigFailed" {
    try testing.expectError(error.ConfigFailed, openVideo(testing.allocator, .{ .width = MAX_VIDEO_DIM + 1, .height = 8, .frame_rate = 30 }));
}

test "openVideo/config/close: 実効値が要求どおり返る" {
    var dev = try openVideo(testing.allocator, .{ .width = 16, .height = 8, .frame_rate = 24 });
    defer dev.close();
    const cfg = dev.config();
    try testing.expectEqual(@as(u32, 16), cfg.width);
    try testing.expectEqual(@as(u32, 8), cfg.height);
    try testing.expectEqual(@as(u32, 24), cfg.frame_rate);
    try testing.expectEqual(capture_types.PixelFormat.bgra8, cfg.format);
}

test "renderFrame: 同一 tick は bit 一致（決定論）" {
    var dev = try openVideo(testing.allocator, .{ .width = 16, .height = 16, .frame_rate = 30 });
    defer dev.close();
    const f1 = dev.renderFrame(7);
    var copy1: [16 * 16]u32 = undefined;
    @memcpy(&copy1, f1.pixels[0 .. 16 * 16]);
    const f2 = dev.renderFrame(7);
    try testing.expectEqualSlices(u32, &copy1, f2.pixels[0 .. 16 * 16]);
    try testing.expectEqual(@as(u64, 7), f2.frame_index);
}

test "renderFrame: 異なる tick は内容が変わる（縮退しない）" {
    var dev = try openVideo(testing.allocator, .{ .width = 16, .height = 16, .frame_rate = 30 });
    defer dev.close();
    const f1 = dev.renderFrame(0);
    var copy1: [16 * 16]u32 = undefined;
    @memcpy(&copy1, f1.pixels[0 .. 16 * 16]);
    const f2 = dev.renderFrame(1);
    try testing.expect(!std.mem.eql(u32, &copy1, f2.pixels[0 .. 16 * 16]));
}

test "renderFrame: tick=0 の (0,0) ブロックは既知の赤" {
    var dev = try openVideo(testing.allocator, .{ .width = 8, .height = 8, .frame_rate = 30 });
    defer dev.close();
    const f = dev.renderFrame(0);
    try testing.expectEqual(@as(u32, 0xFFFF3B30), f.pixels[0]);
}

// --- audio ---

test "enumerateAudio/freeDeviceList: allocator 契約どおり確保・解放できる（リーク検出）" {
    const allocator = testing.allocator;
    const devices = try enumerateAudio(allocator);
    try testing.expectEqual(@as(usize, 1), devices.len);
    try testing.expectEqualStrings("Synthetic Microphone", devices[0].name);
    try testing.expectEqual(capture_types.DeviceKind.audio_in, devices[0].kind);
    capture_types.freeDeviceList(allocator, devices);
}

test "requestAudioPermission: 常に granted" {
    try testing.expectEqual(capture_types.PermissionState.granted, try requestAudioPermission());
}

test "openAudio: sample_rate/channels/block_frames=0 は ConfigFailed" {
    try testing.expectError(error.ConfigFailed, openAudio(testing.allocator, .{ .sample_rate = 0, .capture_callback = noopAudioCallback }));
    try testing.expectError(error.ConfigFailed, openAudio(testing.allocator, .{ .channels = 0, .capture_callback = noopAudioCallback }));
    try testing.expectError(error.ConfigFailed, openAudio(testing.allocator, .{ .block_frames = 0, .capture_callback = noopAudioCallback }));
}

fn noopAudioCallback(frame: capture_types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

const AudioCallCtx = struct {
    count: std.atomic.Value(u32) = .init(0),
    last_frames: std.atomic.Value(u32) = .init(0),
};

fn countingAudioCallback(frame: capture_types.AudioInFrame, userdata: ?*anyopaque) void {
    const ctx: *AudioCallCtx = @ptrCast(@alignCast(userdata.?));
    ctx.last_frames.store(frame.frames, .monotonic);
    _ = ctx.count.fetchAdd(1, .monotonic);
}

test "openAudio/start/stop/close: callback が実時間で複数回呼ばれ、probe 状態(frames/peak)が更新される" {
    var ctx = AudioCallCtx{};
    var dev = try openAudio(testing.allocator, .{
        .sample_rate = 48000,
        .channels = 1,
        .block_frames = 128, // 短い period で速く複数回まわす（≈2.7ms/回）
        .frequency_hz = 440.0,
        .capture_callback = countingAudioCallback,
        .userdata = &ctx,
    });
    defer dev.close();

    try testing.expectEqual(@as(u32, 48000), dev.config().sample_rate);
    try testing.expectEqual(@as(u32, 128), dev.config().max_frames_per_slice);
    try testing.expectEqual(@as(u64, 0), dev.framesGenerated());

    try dev.start();
    sleepNs(30 * std.time.ns_per_ms); // 30ms あれば数回まわる
    dev.stop();

    try testing.expect(ctx.count.load(.monotonic) >= 2);
    try testing.expectEqual(@as(u32, 128), ctx.last_frames.load(.monotonic));
    try testing.expect(dev.framesGenerated() >= 256);
    try testing.expect(dev.lastPeak() > 0); // 非無音（440Hz サイン波の peak > 0）
    try testing.expect(dev.lastPeak() <= 0.31); // 振幅 0.3 を大きく超えない

    // 二重 stop / start(既 close 前) は安全（no-op 相当）
    dev.stop();
}

test "openAudio: RT 契約 - pull ループ稼働中は追加アロケーションが無い（FailingAllocator）" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();

    var ctx = AudioCallCtx{};
    var dev = try openAudio(alloc, .{
        .sample_rate = 48000,
        .channels = 1,
        .block_frames = 64,
        .capture_callback = countingAudioCallback,
        .userdata = &ctx,
    });
    defer dev.close();

    const allocs_after_open = failing.allocations;
    failing.fail_index = allocs_after_open; // 以降 1 回でも alloc されたら OOM になるよう固定

    try dev.start();
    sleepNs(30 * std.time.ns_per_ms);
    dev.stop();

    try testing.expectEqual(allocs_after_open, failing.allocations); // pull ループ中に alloc 無し
    try testing.expect(ctx.count.load(.monotonic) >= 1); // callback は実際に呼ばれている
}

test "periodNanos: sample_rate=0 は 0、そうでなければ period/sample_rate 秒" {
    try testing.expectEqual(@as(u64, 0), periodNanos(512, 0));
    try testing.expectEqual(@as(u64, std.time.ns_per_s), periodNanos(48000, 48000));
}
