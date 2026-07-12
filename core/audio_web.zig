//! Web Audio backend（TASK-73.2: AudioWorklet + SharedArrayBuffer / wasm shared memory）
//!
//! native の RT callback と対称に、AudioWorkletProcessor.process() が
//! `export fn vp_audio_render` を push 駆動する。main thread と worklet は同一 wasm module +
//! 同一 shared linear memory を 2 Instance で共有し、libs/synth の lock-free 機構を無改造で使う。
//!
//! ## EffectiveConfig.sample_rate 方針（notes）
//! `vp_audio_open` の戻り値で JS が構築した `AudioContext.sampleRate`（実 SR）を得る。
//! open 時点で AudioContext は生成可能（autoplay 前でも sampleRate は確定）なので、
//! 「要求値を返して後で atomic 書き戻し」より単純で、open 直後の `device.config()` が正しい。
//!
//! ## shared memory / 2nd Instance の data 初期化（notes）
//! shared memory ビルドでは LLVM/wasm-ld が DataCount + **passive data segment** を生成し、
//! `__wasm_init_memory` の once セマンティクスで data を共有 linear memory へ 1 度だけ適用する。
//! **バイナリ解析で synth.wasm の data segment が 2 本とも passive（+ DataCount section）である
//! ことを確認済み** — 2nd `WebAssembly.Instance` が data を能動再適用して `g_state` を上書きする
//! ことは構造上起きない（/tmp/task-73.2 PoC とも整合）。
//! 加えて実行時 sentinel（`vp_audio_set_sentinel` / `vp_audio_check_sentinel`）で、毎起動ごとに
//! 「2nd instantiate 後も main が書いた共有状態が残っている」ことを実証する。
//!
//! ## boot 時 2nd Instance と g_state（notes）
//! worklet Instance は `boot()` で **vp_init / open より前** に生成する（instantiate 失敗を
//! open 成功より前に検出するため）。この時点では `g_state.callback` は未設定だが、worklet は
//! `running` atomic（acquire）が 1 のときだけ `g_state` を読むため安全。callback 設定は
//! 後続の `open()`、running=1 は `start()`。
//!
//! ## ホットパス宣言
//! RT（毎サンプル）: `vp_audio_render` → 保持した `render_callback`。区間内 alloc/lock/IO/panic なし。
//! 新設ループは無し（samples は caller が渡す out_ptr へ callback が直接書く）。
//! start 前・close 後は atomic フラグで no-op ガード。戻り値 0 のとき worklet は outputs を無音化。

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    OpenFailed,
    NoDevice,
    ConfigFailed,
    InitializeFailed,
    QueryFailed,
    StartFailed,
};

pub const RenderCallback = *const fn (
    buf: []f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    userdata: ?*anyopaque,
) void;

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

// ============================================================================
// JS env imports（vp.js）
// ============================================================================

/// AudioContext + worklet を準備。成功時は実 sample rate (>0)、失敗時 0。
extern "env" fn vp_audio_open(sample_rate: u32, channels: u32, buffer_frames: u32) u32;
extern "env" fn vp_audio_start() void;
extern "env" fn vp_audio_stop() void;
extern "env" fn vp_audio_close() void;

// ============================================================================
// Module-level state（shared linear memory 上。main / worklet 両 Instance から可視）
// ============================================================================

const RenderState = struct {
    callback: RenderCallback = undefined,
    userdata: ?*anyopaque = null,
    channels: u32 = 2,
    sample_rate: u32 = 48000,
    /// 0=stopped/closed, 1=running。worklet の process が読む。
    running: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    opened: bool = false,
};

var g_state: RenderState = .{};

/// 2nd instantiate 後も共有状態が保持されていることを示す sentinel。
/// main が boot 直後に magic を書き、worklet が instantiate 直後に読む。
/// magic = 'VPAS' (0x56504153 LE 解釈の u32 リテラル)。
const SENTINEL_MAGIC: u32 = 0x56504153;
var g_instantiate_sentinel: u32 = 0;

/// worklet Instance 専用スタック領域（shared memory 内の静的バッファ）。
/// スタックは下方向に伸びるので top = base + len を worklet の `__stack_pointer` にセットする。
/// PoC（/tmp/task-73.2）で dual Instance + 独立 SP を確認済み。
const WORKLET_STACK_BYTES = 64 * 1024;
var worklet_stack: [WORKLET_STACK_BYTES]u8 align(16) = undefined;

/// worklet が render 出力を書く共有スクラッチ（max 量子 128 × stereo に余裕）。
/// process() は典型 128 frames。Config.buffer_frames より小さくてもチャンク分割せずそのまま呼ぶ。
const MAX_RENDER_FRAMES = 512;
const MAX_CHANNELS = 2;
var render_scratch: [MAX_RENDER_FRAMES * MAX_CHANNELS]f32 = undefined;

/// main: boot で 2nd Instance 生成前に呼ぶ。shared memory 上に magic を書く。
export fn vp_audio_set_sentinel() void {
    g_instantiate_sentinel = SENTINEL_MAGIC;
}

/// worklet: 2nd instantiate 直後に呼ぶ。magic 一致なら SENTINEL_MAGIC、不一致なら 0。
export fn vp_audio_check_sentinel() u32 {
    if (g_instantiate_sentinel == SENTINEL_MAGIC) return SENTINEL_MAGIC;
    return 0;
}

/// JS / worklet が stack top（バイトアドレス）を読む。
export fn vp_audio_worklet_stack_top() u32 {
    const base = @intFromPtr(&worklet_stack);
    return @intCast(base + WORKLET_STACK_BYTES);
}

/// JS / worklet が render 出力バッファ先頭を読む。
export fn vp_audio_render_buf() u32 {
    return @intCast(@intFromPtr(&render_scratch));
}

/// AudioWorklet process から呼ばれる RT エントリ。
/// **alloc / lock / IO / panic 禁止**。
/// 戻り値: 1 = out_ptr に samples を書いた / 0 = スキップ（worklet は outputs を無音化すること）。
/// frames > MAX や start 前・close 後は 0（古い scratch を出力しない）。
export fn vp_audio_render(out_ptr: u32, frames: u32, channels: u32, sample_rate: u32) u32 {
    if (g_state.running.load(.acquire) == 0) return 0;
    if (frames == 0 or channels == 0) return 0;
    if (frames > MAX_RENDER_FRAMES) return 0;
    if (channels > MAX_CHANNELS) return 0;

    const n: usize = @as(usize, frames) * @as(usize, channels);
    const out: [*]f32 = @ptrFromInt(out_ptr);
    const buf = out[0..n];

    // 未初期化を避けるためゼロ埋め（callback が全サンプル書かない場合のクリック防止）
    @memset(buf, 0);

    const cb = g_state.callback;
    cb(buf, frames, channels, sample_rate, g_state.userdata);
    return 1;
}

pub const AudioDevice = struct {
    effective: EffectiveConfig,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.effective;
    }

    pub fn start(_: AudioDevice) Error!void {
        if (!g_state.opened) return error.StartFailed;
        g_state.running.store(1, .release);
        vp_audio_start();
    }

    pub fn stop(_: AudioDevice) void {
        g_state.running.store(0, .release);
        if (g_state.opened) vp_audio_stop();
    }

    pub fn close(self: AudioDevice) void {
        self.stop();
        if (g_state.opened) {
            vp_audio_close();
            g_state.opened = false;
        }
        g_state.callback = undefined;
        g_state.userdata = null;
    }
};

pub fn open(_: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    if (g_state.opened) return error.OpenFailed;
    if (cfg.channels == 0 or cfg.channels > MAX_CHANNELS) return error.ConfigFailed;
    if (cfg.sample_rate == 0) return error.ConfigFailed;

    g_state.callback = cfg.render_callback;
    g_state.userdata = cfg.userdata;
    g_state.channels = cfg.channels;
    g_state.sample_rate = cfg.sample_rate;
    g_state.running.store(0, .release);

    // JS: boot 済み worklet（audioReady）を確認。戻り値 = 実 sampleRate（0 = 失敗）。
    // COOP/COEP 無し / SharedArrayBuffer 不在 / worklet ロード失敗 / sentinel 失敗 → 0。
    const actual_sr = vp_audio_open(cfg.sample_rate, cfg.channels, cfg.buffer_frames);
    if (actual_sr == 0) {
        g_state.callback = undefined;
        g_state.userdata = null;
        return error.OpenFailed;
    }

    g_state.sample_rate = actual_sr;
    g_state.opened = true;

    // max_frames_per_slice: worklet 量子は通常 128。要求 buffer_frames と 128 の大きい方を上限に。
    // 実際の process は 128 で呼ぶ（不一致でもチャンク分割せずそのまま render）。
    const max_frames = @max(cfg.buffer_frames, @as(u32, 128));
    return .{
        .effective = .{
            .sample_rate = actual_sr,
            .channels = cfg.channels,
            .max_frames_per_slice = @min(max_frames, MAX_RENDER_FRAMES),
        },
    };
}

/// wasm 向け NullBackend 代替（std.Thread 非依存）。`NullBackend(backend)` と同 shape。
pub fn NullWebStub(comptime B: type) type {
    return struct {
        pub const Error = B.Error;
        pub const Config = B.Config;
        pub const EffectiveConfig = B.EffectiveConfig;
        pub const RenderCallback = B.RenderCallback;

        pub const AudioDevice = struct {
            effective: B.EffectiveConfig,

            pub fn config(self: @This()) B.EffectiveConfig {
                return self.effective;
            }

            pub fn start(_: @This()) B.Error!void {}

            pub fn stop(_: @This()) void {}

            pub fn close(_: @This()) void {}
        };

        pub fn open(_: std.mem.Allocator, cfg: B.Config) B.Error!@This().AudioDevice {
            return .{
                .effective = .{
                    .sample_rate = cfg.sample_rate,
                    .channels = cfg.channels,
                    .max_frames_per_slice = cfg.buffer_frames,
                },
            };
        }
    };
}

// rdynamic でも未参照 export が落ちないよう、wasm ビルドで参照を残すフック。
pub fn enableAudioExports() void {
    if (!builtin.cpu.arch.isWasm()) return;
    _ = &vp_audio_render;
    _ = &vp_audio_worklet_stack_top;
    _ = &vp_audio_render_buf;
    _ = &vp_audio_set_sentinel;
    _ = &vp_audio_check_sentinel;
}
