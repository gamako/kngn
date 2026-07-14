//! Linux native audio backend (L1 オーディオ出力プリミティブ)
//!
//! ALSA (libasound) を C ABI で叩き、自前の再生スレッドから render callback を呼んで
//! サンプルを供給する最小の出力デバイスを提供する。AudioToolbox backend と同様に
//! `@cImport` は使わず、必要な ALSA シンボルだけを `extern "c"` 宣言する
//! （audio 層の ABI 戦略を macOS/Linux/Windows で extern fn に統一するため）。
//!
//! スレッドモデル: CoreAudio は OS が RT スレッドで callback を pull するが、ALSA は push。
//! 本 backend は `start()` で再生スレッド (`std.Thread`) を spawn し、`snd_pcm_writei` ループの
//! 中から `render_callback` を呼ぶ。`render_callback` の実行区間では malloc / lock / IO / panic を
//! してはならない（呼び出し側 API 契約。macOS backend と同じ）。`snd_pcm_writei` /
//! `snd_pcm_recover` / `snd_pcm_drop` は callback の外の backend I/O であり契約対象外
//! （ブロッキング I/O 可）。
//!
//! mic capture は末尾の `capture` 名前空間で提供する。ALSA→PipeWire ブリッジを使うには、
//! `/dev/snd/*` の `audio` グループ権限と、PipeWire の ALSA plugin と libasound の整合が必要。
//! capture スレッドは `snd_pcm_readi` で pull し、overrun（`-EPIPE`）を xrun として計数する。
//! callback 区間は RT 契約（malloc/lock/IO/panic 禁止）であり、read/recover は backend I/O として
//! callback の外側にある。

const std = @import("std");
const types = @import("capture_types");

// ============================================================================
// ALSA C ABI (最小サブセット, extern fn / @cImport 不使用)
// ============================================================================
const c = struct {
    pub const snd_pcm_t = opaque {};
    pub const snd_pcm_hw_params_t = opaque {};
    pub const snd_pcm_uframes_t = c_ulong;
    pub const snd_pcm_sframes_t = c_long;
    pub const snd_ctl_t = opaque {};
    pub const snd_ctl_card_info_t = opaque {};

    // snd_pcm_stream_t
    pub const SND_PCM_STREAM_PLAYBACK: c_int = 0;
    pub const SND_PCM_STREAM_CAPTURE: c_int = 1;
    // snd_pcm_access_t
    pub const SND_PCM_ACCESS_RW_INTERLEAVED: c_int = 3;
    // snd_pcm_format_t
    pub const SND_PCM_FORMAT_FLOAT_LE: c_int = 14;
    // errno（Linux）。snd_pcm_writei は負の errno を返す。-EPIPE = underrun。
    pub const EPIPE: c_int = 32;

    pub extern "c" fn snd_pcm_open(pcm: *?*snd_pcm_t, name: [*:0]const u8, stream: c_int, mode: c_int) c_int;
    pub extern "c" fn snd_pcm_close(pcm: *snd_pcm_t) c_int;
    pub extern "c" fn snd_pcm_prepare(pcm: *snd_pcm_t) c_int;
    pub extern "c" fn snd_pcm_writei(pcm: *snd_pcm_t, buffer: *const anyopaque, size: snd_pcm_uframes_t) snd_pcm_sframes_t;
    pub extern "c" fn snd_pcm_readi(pcm: *snd_pcm_t, buffer: *anyopaque, size: snd_pcm_uframes_t) snd_pcm_sframes_t;
    pub extern "c" fn snd_pcm_recover(pcm: *snd_pcm_t, err: c_int, silent: c_int) c_int;
    pub extern "c" fn snd_pcm_drop(pcm: *snd_pcm_t) c_int;

    pub extern "c" fn snd_pcm_hw_params_malloc(ptr: *?*snd_pcm_hw_params_t) c_int;
    pub extern "c" fn snd_pcm_hw_params_free(obj: *snd_pcm_hw_params_t) void;
    pub extern "c" fn snd_pcm_hw_params_any(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_access(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, access: c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_format(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, format: c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_channels(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: c_uint) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_rate_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *c_uint, dir: *c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_period_size_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t, dir: *c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_set_buffer_size_near(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t, val: *snd_pcm_uframes_t) c_int;
    pub extern "c" fn snd_pcm_hw_params(pcm: *snd_pcm_t, params: *snd_pcm_hw_params_t) c_int;
    pub extern "c" fn snd_pcm_hw_params_get_rate(params: *const snd_pcm_hw_params_t, val: *c_uint, dir: *c_int) c_int;
    pub extern "c" fn snd_pcm_hw_params_get_channels(params: *const snd_pcm_hw_params_t, val: *c_uint) c_int;
    pub extern "c" fn snd_pcm_hw_params_get_period_size(params: *const snd_pcm_hw_params_t, val: *snd_pcm_uframes_t, dir: *c_int) c_int;

    // ALSA card enumeration (all calls are initialization/event-time only).
    pub extern "c" fn snd_card_next(card: *c_int) c_int;
    pub extern "c" fn snd_ctl_open(ctl: *?*snd_ctl_t, name: [*:0]const u8, mode: c_int) c_int;
    pub extern "c" fn snd_ctl_close(ctl: *snd_ctl_t) c_int;
    pub extern "c" fn snd_ctl_card_info_malloc(ptr: *?*snd_ctl_card_info_t) c_int;
    pub extern "c" fn snd_ctl_card_info_free(obj: *snd_ctl_card_info_t) void;
    pub extern "c" fn snd_ctl_card_info(ctl: *snd_ctl_t, info: *snd_ctl_card_info_t) c_int;
    pub extern "c" fn snd_ctl_card_info_get_id(info: *const snd_ctl_card_info_t) [*:0]const u8;
    pub extern "c" fn snd_ctl_card_info_get_name(info: *const snd_ctl_card_info_t) [*:0]const u8;
};

// ============================================================================
// 公開型（audio_macos.zig と同一シグネチャ。facade が OS で切り替える）
// ============================================================================

pub const Error = error{
    OpenFailed, // インスタンス生成 / 状態確保失敗
    NoDevice, // 出力デバイス (snd_pcm_open) が開けない
    ConfigFailed, // hw_params 設定失敗
    InitializeFailed, // hw_params commit 失敗
    QueryFailed, // 実効値 query 失敗
    StartFailed, // prepare / 再生スレッド spawn 失敗
};

/// `RenderCallback` は再生スレッドで呼ばれる。**malloc / lock / IO / panic をしてはならない**。
/// `buf` は interleaved な `frames * channels` 要素の f32 スライス（書き込み先）。
pub const RenderCallback = *const fn (
    buf: []f32,
    frames: u32,
    channels: u32,
    sample_rate: u32,
    userdata: ?*anyopaque,
) void;

/// 要求設定（あくまでヒント）。実効値は `open()` 後に `device.config()` で取得する。
pub const Config = struct {
    sample_rate: u32 = 48000,
    buffer_frames: u32 = 512, // ALSA では period size のヒントに使う
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

/// `open()` がデバイスから query した実効値。
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32, // ALSA の period size（1 回の render で埋める frame 数）
};

/// 再生スレッド / callback に安定アドレスで渡すための状態。`open()` で heap 確保し
/// `close()` で破棄する（ローカル変数の参照を渡さない = UAF 防止）。
const State = struct {
    pcm: *c.snd_pcm_t,
    render_callback: RenderCallback,
    userdata: ?*anyopaque,
    effective: EffectiveConfig,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,
    scratch: []f32, // period * channels の interleaved バッファ
    xrun_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,
};

pub const AudioDevice = struct {
    state: *State,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.state.effective;
    }

    /// 再生スレッドを起動する。初期化失敗（prepare / spawn）は `error.StartFailed`。
    /// prepare を spawn 前に行い、失敗を `start()` の戻り値に寄せる
    /// （macOS の `AudioOutputUnitStart` 失敗 → `StartFailed` と対称）。
    pub fn start(self: AudioDevice) Error!void {
        const state = self.state;
        if (state.thread != null) return; // 二重 start は無視
        if (c.snd_pcm_prepare(state.pcm) < 0) return error.StartFailed;
        state.running.store(true, .release);
        state.thread = std.Thread.spawn(.{}, renderThread, .{state}) catch {
            state.running.store(false, .release);
            return error.StartFailed;
        };
    }

    /// 再生スレッドを止める。`running=false` → join → `snd_pcm_drop`（即時停止）。
    /// join は in-flight の writei 完了待ちになるため停止レイテンシは最大 1 period 程度。
    pub fn stop(self: AudioDevice) void {
        const state = self.state;
        if (state.thread) |thread| {
            state.running.store(false, .release);
            thread.join();
            state.thread = null;
            _ = c.snd_pcm_drop(state.pcm);
        }
    }

    /// stop → close → scratch 解放 → State 破棄。
    pub fn close(self: AudioDevice) void {
        const state = self.state;
        self.stop();
        _ = c.snd_pcm_close(state.pcm);
        state.allocator.free(state.scratch);
        state.allocator.destroy(state);
    }
};

// ============================================================================
// 再生スレッド（push モデル: writei ループから render_callback を pull）
// ============================================================================
fn renderThread(state: *State) void {
    const ch: usize = state.effective.channels;
    const period: usize = state.effective.max_frames_per_slice;
    const sample_rate = state.effective.sample_rate;

    while (state.running.load(.acquire)) {
        // 1 period 分を埋める（RT 契約区間: alloc/lock/IO/panic 禁止）。
        state.render_callback(
            state.scratch,
            @intCast(period),
            @intCast(ch),
            sample_rate,
            state.userdata,
        );

        // period frames を書き切る（partial write 対応: 残りを書き切るまで次の render を呼ばない）。
        var offset: usize = 0;
        while (offset < period) {
            const frames = period - offset;
            const ptr: *const anyopaque = @ptrCast(state.scratch.ptr + offset * ch);
            const n = c.snd_pcm_writei(state.pcm, ptr, @intCast(frames));
            if (n < 0) {
                // 実際の戻り値をそのまま recover に渡し、-EPIPE/-ESTRPIPE/-EINTR を一律処理する。
                const err: c_int = @intCast(n);
                if (err == -c.EPIPE) _ = state.xrun_count.fetchAdd(1, .monotonic); // underrun のみ計数
                if (c.snd_pcm_recover(state.pcm, err, 1) < 0) {
                    state.running.store(false, .release); // 回復不能ならループ終了
                }
                break; // 当該 period は破棄（再送しない）。次 period から再開
            }
            if (n == 0) break; // 進捗ゼロ（busy-loop 防止）: 当該 period を破棄して次 period へ
            offset += @intCast(n);
        }
    }
}

// ============================================================================
// open
// ============================================================================
pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    // 1. デフォルト PCM を playback / blocking で開く
    var pcm: ?*c.snd_pcm_t = null;
    if (c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.NoDevice;
    const handle = pcm orelse return error.NoDevice;
    errdefer _ = c.snd_pcm_close(handle);

    // 2. hw_params を設定（alloca マクロは translate-c 不可なので malloc/free を使う。open 時のみ）
    var params: ?*c.snd_pcm_hw_params_t = null;
    if (c.snd_pcm_hw_params_malloc(&params) < 0) return error.OpenFailed;
    const hw = params orelse return error.OpenFailed;
    defer c.snd_pcm_hw_params_free(hw);

    if (c.snd_pcm_hw_params_any(handle, hw) < 0) return error.ConfigFailed;
    if (c.snd_pcm_hw_params_set_access(handle, hw, c.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return error.ConfigFailed;
    if (c.snd_pcm_hw_params_set_format(handle, hw, c.SND_PCM_FORMAT_FLOAT_LE) < 0) return error.ConfigFailed;
    if (c.snd_pcm_hw_params_set_channels(handle, hw, @intCast(cfg.channels)) < 0) return error.ConfigFailed;

    var rate: c_uint = @intCast(cfg.sample_rate);
    var dir: c_int = 0;
    if (c.snd_pcm_hw_params_set_rate_near(handle, hw, &rate, &dir) < 0) return error.ConfigFailed;

    var period: c.snd_pcm_uframes_t = @intCast(cfg.buffer_frames);
    dir = 0;
    if (c.snd_pcm_hw_params_set_period_size_near(handle, hw, &period, &dir) < 0) return error.ConfigFailed;

    // buffer は数 period 分（latency と underrun 耐性のバランス）。near なのでデバイス都合で丸まる。
    var buffer_size: c.snd_pcm_uframes_t = period * 4;
    if (c.snd_pcm_hw_params_set_buffer_size_near(handle, hw, &buffer_size) < 0) return error.ConfigFailed;

    if (c.snd_pcm_hw_params(handle, hw) < 0) return error.InitializeFailed;

    // 3. 実効値を query（要求値がそのまま通る保証はない = macOS と同契約）
    var actual_rate: c_uint = 0;
    dir = 0;
    if (c.snd_pcm_hw_params_get_rate(hw, &actual_rate, &dir) < 0) return error.QueryFailed;
    var actual_channels: c_uint = 0;
    if (c.snd_pcm_hw_params_get_channels(hw, &actual_channels) < 0) return error.QueryFailed;
    var actual_period: c.snd_pcm_uframes_t = 0;
    dir = 0;
    if (c.snd_pcm_hw_params_get_period_size(hw, &actual_period, &dir) < 0) return error.QueryFailed;

    const effective = EffectiveConfig{
        .sample_rate = @intCast(actual_rate),
        .channels = @intCast(actual_channels),
        .max_frames_per_slice = @intCast(actual_period),
    };

    // 4. State と scratch を heap 確保（安定アドレス）
    const state = allocator.create(State) catch return error.OpenFailed;
    errdefer allocator.destroy(state);

    const scratch = allocator.alloc(f32, @as(usize, effective.max_frames_per_slice) * effective.channels) catch
        return error.OpenFailed;
    errdefer allocator.free(scratch);

    state.* = .{
        .pcm = handle,
        .render_callback = cfg.render_callback,
        .userdata = cfg.userdata,
        .effective = effective,
        .running = std.atomic.Value(bool).init(false),
        .thread = null,
        .scratch = scratch,
        .xrun_count = std.atomic.Value(u32).init(0),
        .allocator = allocator,
    };

    return .{ .state = state };
}

// ============================================================================
// mic capture (ALSA / PipeWire)
// ============================================================================

pub const capture = struct {
    const PERIOD_FRAMES: u32 = 512;

    pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

    pub const Config = struct {
        device_id: ?[]const u8 = null, // MVP は default PCM 固定。列挙 id は将来の選択経路用。
        sample_rate: u32 = 48000,
        channels: u32 = 1,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque = null,
    };

    pub const EffectiveConfig = struct {
        sample_rate: u32,
        channels: u32,
        max_frames_per_slice: u32,
    };

    const State = struct {
        pcm: *c.snd_pcm_t,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque,
        effective: capture.EffectiveConfig,
        running: std.atomic.Value(bool),
        thread: ?std.Thread,
        scratch: []f32,
        xrun_count: std.atomic.Value(u32),
        allocator: std.mem.Allocator,
    };

    pub const CaptureDevice = struct {
        state: *capture.State,

        pub fn config(self: CaptureDevice) capture.EffectiveConfig {
            return self.state.effective;
        }

        pub fn start(self: CaptureDevice) types.CaptureError!void {
            const state = self.state;
            if (state.thread != null) return;
            if (c.snd_pcm_prepare(state.pcm) < 0) return error.StartFailed;
            state.running.store(true, .release);
            state.thread = std.Thread.spawn(.{}, captureThread, .{state}) catch {
                state.running.store(false, .release);
                _ = c.snd_pcm_drop(state.pcm);
                return error.StartFailed;
            };
        }

        /// `running=false` を先に公開し、`snd_pcm_drop` で blocking readi を解除してから join する。
        pub fn stop(self: CaptureDevice) void {
            const state = self.state;
            if (state.thread) |thread| {
                state.running.store(false, .release);
                _ = c.snd_pcm_drop(state.pcm);
                thread.join();
                state.thread = null;
            }
        }

        pub fn close(self: CaptureDevice) void {
            const state = self.state;
            self.stop();
            _ = c.snd_pcm_close(state.pcm);
            state.allocator.free(state.scratch);
            state.allocator.destroy(state);
        }
    };

    /// ALSA カードを列挙する。MVP では入力 capability の厳密判定をせず、存在するカードを返す。
    pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
        var list: std.ArrayList(types.DeviceInfo) = .empty;
        errdefer {
            for (list.items) |item| {
                allocator.free(item.id);
                allocator.free(item.name);
            }
            list.deinit(allocator);
        }

        var card: c_int = -1;
        while (true) {
            if (c.snd_card_next(&card) < 0) return error.OpenFailed;
            if (card < 0) break;

            var ctl_name_buf: [32:0]u8 = undefined;
            const ctl_name = std.fmt.bufPrintZ(&ctl_name_buf, "hw:{d}", .{card}) catch return error.OpenFailed;
            var ctl: ?*c.snd_ctl_t = null;
            if (c.snd_ctl_open(&ctl, ctl_name, 0) < 0) continue;
            const handle = ctl orelse continue;
            defer _ = c.snd_ctl_close(handle);

            var info: ?*c.snd_ctl_card_info_t = null;
            if (c.snd_ctl_card_info_malloc(&info) < 0) return error.OpenFailed;
            const card_info = info orelse return error.OpenFailed;
            defer c.snd_ctl_card_info_free(card_info);
            if (c.snd_ctl_card_info(handle, card_info) < 0) continue;

            // Card-info id is queried for the raw ALSA metadata; the public id is the stable
            // control name used by open/enumeration (`hw:N`) per the capture plan.
            _ = c.snd_ctl_card_info_get_id(card_info);
            const id = allocator.dupe(u8, ctl_name[0..ctl_name.len]) catch return error.OpenFailed;
            errdefer allocator.free(id);
            const name = allocator.dupe(u8, std.mem.span(c.snd_ctl_card_info_get_name(card_info))) catch return error.OpenFailed;
            errdefer allocator.free(name);
            list.append(allocator, .{
                .id = id,
                .name = name,
                .kind = .audio_in,
                .is_default = card == 0,
            }) catch return error.OpenFailed;
        }
        return list.toOwnedSlice(allocator) catch return error.OpenFailed;
    }

    /// Linux には TCC ダイアログが無いため、default PCM の trial-open で権限だけを判定する。
    pub fn requestPermission() types.CaptureError!types.PermissionState {
        var pcm: ?*c.snd_pcm_t = null;
        const rc = c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_CAPTURE, 0);
        if (rc >= 0) {
            if (pcm) |handle| _ = c.snd_pcm_close(handle);
            return .granted;
        }
        return switch (rc) {
            -1, -13 => .denied, // EPERM / EACCES
            else => .not_determined,
        };
    }

    fn captureThread(state: *capture.State) void {
        const ch: usize = state.effective.channels;
        const period = state.effective.max_frames_per_slice;
        while (state.running.load(.acquire)) {
            const n = c.snd_pcm_readi(state.pcm, @ptrCast(state.scratch.ptr), @intCast(period));
            if (n < 0) {
                const err: c_int = @intCast(n);
                if (err == -c.EPIPE) _ = state.xrun_count.fetchAdd(1, .monotonic); // capture overrun
                if (c.snd_pcm_recover(state.pcm, err, 1) < 0) state.running.store(false, .release);
                continue;
            }
            if (n == 0) continue;
            const frames: u32 = @intCast(n);
            state.capture_callback(.{
                .samples = state.scratch[0 .. @as(usize, frames) * ch],
                .frames = frames,
                .channels = state.effective.channels,
                .sample_rate = state.effective.sample_rate,
                .timestamp_ns = 0,
            }, state.userdata);
        }
    }

    pub fn open(allocator: std.mem.Allocator, cfg: capture.Config) types.CaptureError!CaptureDevice {
        if (cfg.sample_rate == 0 or cfg.channels == 0) return error.ConfigFailed;

        var pcm: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm, "default", c.SND_PCM_STREAM_CAPTURE, 0) < 0) return error.NoDevice;
        const handle = pcm orelse return error.NoDevice;
        errdefer _ = c.snd_pcm_close(handle);

        var params: ?*c.snd_pcm_hw_params_t = null;
        if (c.snd_pcm_hw_params_malloc(&params) < 0) return error.OpenFailed;
        const hw = params orelse return error.OpenFailed;
        defer c.snd_pcm_hw_params_free(hw);
        if (c.snd_pcm_hw_params_any(handle, hw) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params_set_access(handle, hw, c.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params_set_format(handle, hw, c.SND_PCM_FORMAT_FLOAT_LE) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params_set_channels(handle, hw, @intCast(cfg.channels)) < 0) return error.ConfigFailed;
        var rate: c_uint = @intCast(cfg.sample_rate);
        var dir: c_int = 0;
        if (c.snd_pcm_hw_params_set_rate_near(handle, hw, &rate, &dir) < 0) return error.ConfigFailed;
        var period: c.snd_pcm_uframes_t = PERIOD_FRAMES;
        dir = 0;
        if (c.snd_pcm_hw_params_set_period_size_near(handle, hw, &period, &dir) < 0) return error.ConfigFailed;
        var buffer_size = period * 4;
        if (c.snd_pcm_hw_params_set_buffer_size_near(handle, hw, &buffer_size) < 0) return error.ConfigFailed;
        if (c.snd_pcm_hw_params(handle, hw) < 0) return error.OpenFailed;

        var actual_rate: c_uint = 0;
        dir = 0;
        if (c.snd_pcm_hw_params_get_rate(hw, &actual_rate, &dir) < 0) return error.OpenFailed;
        var actual_channels: c_uint = 0;
        if (c.snd_pcm_hw_params_get_channels(hw, &actual_channels) < 0) return error.OpenFailed;
        var actual_period: c.snd_pcm_uframes_t = 0;
        dir = 0;
        if (c.snd_pcm_hw_params_get_period_size(hw, &actual_period, &dir) < 0) return error.OpenFailed;
        const effective = capture.EffectiveConfig{ .sample_rate = @intCast(actual_rate), .channels = @intCast(actual_channels), .max_frames_per_slice = @intCast(actual_period) };
        const state = allocator.create(capture.State) catch return error.OpenFailed;
        errdefer allocator.destroy(state);
        const scratch = allocator.alloc(f32, @as(usize, effective.max_frames_per_slice) * effective.channels) catch return error.OpenFailed;
        errdefer allocator.free(scratch);
        state.* = .{
            .pcm = handle,
            .capture_callback = cfg.capture_callback,
            .userdata = cfg.userdata,
            .effective = effective,
            .running = .init(false),
            .thread = null,
            .scratch = scratch,
            .xrun_count = .init(0),
            .allocator = allocator,
        };
        return .{ .state = state };
    }
};

const testing = std.testing;

fn noopCaptureCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

/// 手動フルサイクルテスト用 callback（RT スレッドで呼ばれる。userdata=受信 frame 数の atomic）。
fn smokeMicCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    const counter: *std.atomic.Value(u64) = @ptrCast(@alignCast(userdata.?));
    _ = counter.fetchAdd(frame.frames, .monotonic);
}

test "capture.open: sample_rate/channels=0 は ALSA を呼ばず ConfigFailed" {
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .sample_rate = 0, .capture_callback = noopCaptureCallback }));
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .channels = 0, .capture_callback = noopCaptureCallback }));
}

test "capture.enumerate/requestPermission: 実 ALSA を呼んでもクラッシュ/ハングせず妥当な結果を返す" {
    // カード有無は環境依存なので台数は assert しない。snd_card_next / snd_ctl_open("hw:N") は
    // 即時で PipeWire を介さないためハングしない。id/name の allocator 契約も同時に検証する。
    const devices = try capture.enumerate(testing.allocator);
    defer types.freeDeviceList(testing.allocator, devices);
    // requestPermission は default PCH の trial-open。PipeWire ブリッジ経由でも open は即返る。
    const perm = try capture.requestPermission();
    try testing.expect(perm == .granted or perm == .denied or perm == .not_determined);
    if (std.c.getenv("VP_CAPTURE_SMOKE") != null) {
        std.debug.print("[alsa smoke] enumerate -> {d} card(s)", .{devices.len});
        for (devices) |d| std.debug.print(" [{s}={s}]", .{ d.id, d.name });
        std.debug.print("; requestPermission -> {s}\n", .{@tagName(perm)});
    }
}

// 手動検証専用（既定 SkipZigTest。実マイクを掴むため VP_CAPTURE_FULL_SMOKE=1 の時のみ実行）。
// open→start→capture callback→stop→close の全サイクルと、stop() の snd_pcm_drop が blocking readi を
// unblock して join できるかを実機で確認する。デバイス/PipeWire 不在は best-effort で許容。
test "capture full cycle (manual): open→start→callback→stop→close が実マイクでハングせず回る" {
    if (std.c.getenv("VP_CAPTURE_FULL_SMOKE") == null) return error.SkipZigTest;
    var frames: std.atomic.Value(u64) = .init(0);
    var dev = capture.open(testing.allocator, .{ .sample_rate = 48000, .channels = 1, .capture_callback = smokeMicCallback, .userdata = &frames }) catch |err| {
        std.debug.print("[alsa full] open failed: {s}（best-effort: sink/PipeWire 不在で許容）\n", .{@errorName(err)});
        return;
    };
    defer dev.close();
    const eff = dev.config();
    std.debug.print("[alsa full] open ok: {d}Hz {d}ch period={d}\n", .{ eff.sample_rate, eff.channels, eff.max_frames_per_slice });
    try dev.start();
    var tries: usize = 0;
    while (tries < 100 and frames.load(.monotonic) == 0) : (tries += 1) {
        var req = std.c.timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&req, null);
    }
    std.debug.print("[alsa full] frames captured: {d}\n", .{frames.load(.monotonic)});
    dev.stop(); // ← snd_pcm_drop で blocking readi を unblock → join。ハングしないことが主眼。
    std.debug.print("[alsa full] stop/close ok（snd_pcm_drop が readi を unblock した）\n", .{});
}
