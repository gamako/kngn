//! macOS native audio backend (L1 オーディオ出力プリミティブ)
//!
//! AudioUnit (Default Output Unit) を C ABI で叩き、レンダーコールバックで
//! サンプルを供給する最小の出力デバイスを提供する。AudioToolbox の必要シンボルだけを
//! `extern` 宣言する（`@cImport` は使わない: framework header search path 不要で build が単純）。
//!
//! スレッドモデル: `render_callback` は CoreAudio が管理する **RT スレッド**で呼ばれる。
//! その中で malloc / lock / IO / panic をしてはならない（呼び出し側の API 契約）。

const std = @import("std");

// ============================================================================
// AudioToolbox C ABI (最小サブセット)
// ============================================================================
const c = struct {
    pub const OSStatus = i32;
    pub const OSType = u32;

    const AudioComponentImpl = opaque {};
    pub const AudioComponent = ?*AudioComponentImpl;
    const ComponentInstanceImpl = opaque {};
    pub const AudioComponentInstance = ?*ComponentInstanceImpl;
    pub const AudioUnit = AudioComponentInstance;

    pub const AudioComponentDescription = extern struct {
        componentType: OSType,
        componentSubType: OSType,
        componentManufacturer: OSType,
        componentFlags: u32,
        componentFlagsMask: u32,
    };

    pub const AudioStreamBasicDescription = extern struct {
        mSampleRate: f64,
        mFormatID: u32,
        mFormatFlags: u32,
        mBytesPerPacket: u32,
        mFramesPerPacket: u32,
        mBytesPerFrame: u32,
        mChannelsPerFrame: u32,
        mBitsPerChannel: u32,
        mReserved: u32,
    };

    pub const AudioBuffer = extern struct {
        mNumberChannels: u32,
        mDataByteSize: u32,
        mData: ?*anyopaque,
    };

    pub const AudioBufferList = extern struct {
        mNumberBuffers: u32,
        mBuffers: [1]AudioBuffer,
    };

    pub const AURenderCallback = *const fn (
        in_ref_con: ?*anyopaque,
        io_action_flags: ?*anyopaque, // AudioUnitRenderActionFlags*
        in_time_stamp: ?*const anyopaque, // const AudioTimeStamp*
        in_bus_number: u32,
        in_number_frames: u32,
        io_data: ?*AudioBufferList,
    ) callconv(.c) OSStatus;

    pub const AURenderCallbackStruct = extern struct {
        inputProc: AURenderCallback,
        inputProcRefCon: ?*anyopaque,
    };

    // FourCharCode 定数
    pub const kAudioUnitType_Output: OSType = 0x6175_6F75; // 'auou'
    pub const kAudioUnitSubType_DefaultOutput: OSType = 0x6465_6620; // 'def '
    pub const kAudioUnitManufacturer_Apple: OSType = 0x6170_706C; // 'appl'
    pub const kAudioFormatLinearPCM: OSType = 0x6C70_636D; // 'lpcm'

    pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
    pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;

    pub const kAudioUnitProperty_StreamFormat: u32 = 8;
    pub const kAudioUnitProperty_MaximumFramesPerSlice: u32 = 14;
    pub const kAudioUnitProperty_SetRenderCallback: u32 = 23;

    pub const kAudioUnitScope_Global: u32 = 0;
    pub const kAudioUnitScope_Input: u32 = 1;
    pub const kAudioUnitScope_Output: u32 = 2;

    pub extern "c" fn AudioComponentFindNext(in_component: AudioComponent, in_desc: *const AudioComponentDescription) AudioComponent;
    pub extern "c" fn AudioComponentInstanceNew(in_component: AudioComponent, out_instance: *AudioComponentInstance) OSStatus;
    pub extern "c" fn AudioComponentInstanceDispose(in_instance: AudioComponentInstance) OSStatus;
    pub extern "c" fn AudioUnitSetProperty(in_unit: AudioUnit, in_id: u32, in_scope: u32, in_element: u32, in_data: ?*const anyopaque, in_data_size: u32) OSStatus;
    pub extern "c" fn AudioUnitGetProperty(in_unit: AudioUnit, in_id: u32, in_scope: u32, in_element: u32, out_data: ?*anyopaque, io_data_size: *u32) OSStatus;
    pub extern "c" fn AudioUnitInitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioUnitUninitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStart(ci: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStop(ci: AudioUnit) OSStatus;
};

// ============================================================================
// 公開型
// ============================================================================

pub const Error = error{
    OpenFailed, // インスタンス生成失敗
    NoDevice, // 出力デバイスが見つからない
    ConfigFailed, // SetProperty (StreamFormat / RenderCallback) 失敗
    InitializeFailed, // AudioUnitInitialize 失敗
    QueryFailed, // GetProperty (実効値) 失敗
    StartFailed, // AudioOutputUnitStart 失敗
};

/// `RenderCallback` は RT スレッドで呼ばれる。**malloc / lock / IO / panic をしてはならない**。
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
    buffer_frames: u32 = 512, // 27.1 では未使用（実効フレーム数は callback の frames を正とする）
    channels: u32 = 2,
    render_callback: RenderCallback,
    userdata: ?*anyopaque = null,
};

/// `open()` がデバイスから query した実効値。
pub const EffectiveConfig = struct {
    sample_rate: u32,
    channels: u32,
    max_frames_per_slice: u32,
};

/// RT スレッドの callback に安定アドレスで渡すための状態。`open()` で heap 確保し
/// `close()` で破棄する（ローカル変数の参照を refCon に渡さない = UAF 防止）。
const State = struct {
    unit: c.AudioUnit,
    render_callback: RenderCallback,
    userdata: ?*anyopaque,
    effective: EffectiveConfig,
    running: bool,
    allocator: std.mem.Allocator,
};

pub const AudioDevice = struct {
    state: *State,

    pub fn config(self: AudioDevice) EffectiveConfig {
        return self.state.effective;
    }

    pub fn start(self: AudioDevice) Error!void {
        if (c.AudioOutputUnitStart(self.state.unit) != 0) return error.StartFailed;
        self.state.running = true;
    }

    pub fn stop(self: AudioDevice) void {
        if (self.state.running) {
            _ = c.AudioOutputUnitStop(self.state.unit);
            self.state.running = false;
        }
    }

    /// running なら stop → uninitialize → dispose → State 破棄。途中の失敗でも dispose まで進める。
    pub fn close(self: AudioDevice) void {
        const state = self.state;
        if (state.running) {
            _ = c.AudioOutputUnitStop(state.unit);
            state.running = false;
        }
        _ = c.AudioUnitUninitialize(state.unit);
        _ = c.AudioComponentInstanceDispose(state.unit);
        state.allocator.destroy(state);
    }
};

// ============================================================================
// RT スレッドで呼ばれる trampoline
// ============================================================================
fn renderTrampoline(
    in_ref_con: ?*anyopaque,
    io_action_flags: ?*anyopaque,
    in_time_stamp: ?*const anyopaque,
    in_bus_number: u32,
    in_number_frames: u32,
    io_data: ?*c.AudioBufferList,
) callconv(.c) c.OSStatus {
    _ = io_action_flags;
    _ = in_time_stamp;
    _ = in_bus_number;

    // 異常は panic せず guard で弾く（RT スレッドのため）。
    const state: *State = @ptrCast(@alignCast(in_ref_con orelse return 0));
    const list = io_data orelse return 0;
    if (list.mNumberBuffers != 1) return 0; // interleaved stereo 前提
    const data_ptr = list.mBuffers[0].mData orelse return 0;

    const channels = state.effective.channels;
    const count = @as(usize, in_number_frames) * @as(usize, channels);
    const samples: [*]f32 = @ptrCast(@alignCast(data_ptr));

    state.render_callback(
        samples[0..count],
        in_number_frames,
        channels,
        state.effective.sample_rate,
        state.userdata,
    );
    return 0;
}

// ============================================================================
// open
// ============================================================================
pub fn open(allocator: std.mem.Allocator, cfg: Config) Error!AudioDevice {
    // 1. Default Output Unit を探してインスタンス化
    const desc = c.AudioComponentDescription{
        .componentType = c.kAudioUnitType_Output,
        .componentSubType = c.kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = c.kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0,
    };
    const comp = c.AudioComponentFindNext(null, &desc) orelse return error.NoDevice;
    var unit: c.AudioUnit = null;
    if (c.AudioComponentInstanceNew(comp, &unit) != 0) return error.OpenFailed;
    errdefer _ = c.AudioComponentInstanceDispose(unit);

    const state = allocator.create(State) catch return error.OpenFailed;
    errdefer allocator.destroy(state);
    state.* = .{
        .unit = unit,
        .render_callback = cfg.render_callback,
        .userdata = cfg.userdata,
        .effective = undefined,
        .running = false,
        .allocator = allocator,
    };

    // 2. StreamFormat (float32 / interleaved stereo) を Input scope, element 0 に設定
    const asbd = c.AudioStreamBasicDescription{
        .mSampleRate = @floatFromInt(cfg.sample_rate),
        .mFormatID = c.kAudioFormatLinearPCM,
        .mFormatFlags = c.kAudioFormatFlagIsFloat | c.kAudioFormatFlagIsPacked,
        .mBytesPerPacket = cfg.channels * 4,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = cfg.channels * 4,
        .mChannelsPerFrame = cfg.channels,
        .mBitsPerChannel = 32,
        .mReserved = 0,
    };
    if (c.AudioUnitSetProperty(
        unit,
        c.kAudioUnitProperty_StreamFormat,
        c.kAudioUnitScope_Input,
        0,
        &asbd,
        @sizeOf(c.AudioStreamBasicDescription),
    ) != 0) return error.ConfigFailed;

    // 3. RenderCallback を Input scope, element 0 に設定（refCon = 安定アドレスの state）
    const cb = c.AURenderCallbackStruct{
        .inputProc = renderTrampoline,
        .inputProcRefCon = state,
    };
    if (c.AudioUnitSetProperty(
        unit,
        c.kAudioUnitProperty_SetRenderCallback,
        c.kAudioUnitScope_Input,
        0,
        &cb,
        @sizeOf(c.AURenderCallbackStruct),
    ) != 0) return error.ConfigFailed;

    // 4. Initialize（StreamFormat / RenderCallback 設定の後）
    if (c.AudioUnitInitialize(unit) != 0) return error.InitializeFailed;
    errdefer _ = c.AudioUnitUninitialize(unit);

    // 5. 実効値を query（要求値がそのまま通る保証はない）
    var actual = std.mem.zeroes(c.AudioStreamBasicDescription);
    var asbd_size: u32 = @sizeOf(c.AudioStreamBasicDescription);
    if (c.AudioUnitGetProperty(
        unit,
        c.kAudioUnitProperty_StreamFormat,
        c.kAudioUnitScope_Input,
        0,
        &actual,
        &asbd_size,
    ) != 0) return error.QueryFailed;

    var max_frames: u32 = 0;
    var mf_size: u32 = @sizeOf(u32);
    if (c.AudioUnitGetProperty(
        unit,
        c.kAudioUnitProperty_MaximumFramesPerSlice,
        c.kAudioUnitScope_Global,
        0,
        &max_frames,
        &mf_size,
    ) != 0) return error.QueryFailed;

    state.effective = .{
        .sample_rate = @intFromFloat(actual.mSampleRate),
        .channels = actual.mChannelsPerFrame,
        .max_frames_per_slice = max_frames,
    };

    return .{ .state = state };
}
