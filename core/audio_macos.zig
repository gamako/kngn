//! macOS native audio backend (L1 オーディオ出力プリミティブ)
//!
//! AudioUnit (Default Output Unit) を C ABI で叩き、レンダーコールバックで
//! サンプルを供給する最小の出力デバイスを提供する。AudioToolbox の必要シンボルだけを
//! `extern` 宣言する（`@cImport` は使わない: framework header search path 不要で build が単純）。
//!
//! スレッドモデル: `render_callback` は CoreAudio が管理する **RT スレッド**で呼ばれる。
//! その中で malloc / lock / IO / panic をしてはならない（呼び出し側の API 契約）。
//!
//! ## mic capture（AUHAL input。TASK-49.2。末尾 `pub const capture = struct {...}` 節）
//!
//! 出力（Default Output Unit）の鏡像として、AUHAL（`kAudioUnitSubType_HALOutput`）の入力
//! element を有効化し、`AudioUnitRender` で pull した PCM を `capture_types.AudioInFrame` として
//! ユーザー `CaptureCallback` へ渡す。名前空間を `capture` にネストするのは、既存の出力用
//! `Config`/`EffectiveConfig`/`AudioDevice`（このファイル上部）と capture 側の同名型が
//! 1ファイル内で衝突しないようにするため（`core/audio.zig` の `capture_backend` は
//! macOS でこの `capture` 名前空間を指す。他 backend ファイルとの duck-typing 規約は
//! `core/audio_capture_stub.zig` と同形）。
//! 権限確認（`AVCaptureDevice.authorizationStatusForMediaType:`/`requestAccessForMediaType:`）は
//! camera 側と同じ ObjC ランタイム経由（`core/objc_runtime.zig`。設計文書
//! `docs/plans/capture-foundation-plan.md` 6章の mic permission 欄を参照）。
//!
//! ホットパス宣言: input callback（`inputTrampoline`）は **RT スレッド（CoreAudio 管理。毎コール
//! バック=数msごと）**。区間内で malloc/lock/IO/panic 禁止（既存出力 `renderTrampoline` と同じ
//! 契約）。行うのは `AudioUnitRender`（固定確保済み `scratch` バッファへ pull）+ ユーザー
//! `CaptureCallback` 呼び出しのみ。

const std = @import("std");
const types = @import("capture_types");
const objc = @import("objc_runtime");

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

    // ------------------------------------------------------------------
    // AUHAL input（mic capture。TASK-49.2）追加分。値は Apple SDK ヘッダ
    // （AudioUnit/AudioUnitProperties.h, CoreAudio/AudioHardwareBase.h,
    //   CoreAudio/AudioHardware.h）から実測確認済み。
    // ------------------------------------------------------------------
    pub const kAudioUnitSubType_HALOutput: OSType = 0x6168_616C; // 'ahal'

    pub const kAudioOutputUnitProperty_CurrentDevice: u32 = 2000;
    pub const kAudioOutputUnitProperty_EnableIO: u32 = 2003;
    pub const kAudioOutputUnitProperty_SetInputCallback: u32 = 2005;

    pub extern "c" fn AudioUnitRender(ci: AudioUnit, io_action_flags: ?*anyopaque, in_time_stamp: ?*const anyopaque, in_bus_number: u32, in_number_frames: u32, io_data: *AudioBufferList) OSStatus;

    // CoreAudio HAL（AudioObject。デバイス列挙・既定入力デバイス取得用）。
    pub const AudioObjectID = u32;
    pub const AudioObjectPropertyAddress = extern struct {
        mSelector: u32,
        mScope: u32,
        mElement: u32,
    };
    pub const kAudioObjectSystemObject: AudioObjectID = 1;
    pub const kAudioObjectPropertyScopeGlobal: u32 = 0x676C_6F62; // 'glob'
    pub const kAudioObjectPropertyScopeInput: u32 = 0x696E_7074; // 'inpt'
    pub const kAudioObjectPropertyElementMain: u32 = 0;
    pub const kAudioObjectPropertyName: u32 = 0x6C6E_616D; // 'lnam'
    pub const kAudioHardwarePropertyDevices: u32 = 0x6465_7623; // 'dev#'
    pub const kAudioHardwarePropertyDefaultInputDevice: u32 = 0x6449_6E20; // 'dIn '
    pub const kAudioDevicePropertyStreams: u32 = 0x7374_6D23; // 'stm#'
    pub const kAudioDevicePropertyDeviceUID: u32 = 0x7569_6420; // 'uid '

    pub extern "c" fn AudioObjectGetPropertyDataSize(object_id: AudioObjectID, address: *const AudioObjectPropertyAddress, qualifier_data_size: u32, qualifier_data: ?*const anyopaque, out_data_size: *u32) OSStatus;
    pub extern "c" fn AudioObjectGetPropertyData(object_id: AudioObjectID, address: *const AudioObjectPropertyAddress, qualifier_data_size: u32, qualifier_data: ?*const anyopaque, io_data_size: *u32, out_data: ?*anyopaque) OSStatus;
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

// ============================================================================
// mic capture（AUHAL input。TASK-49.2。ファイル冒頭のホットパス宣言参照）
// ============================================================================

/// AVFoundation.framework が公開する `NSString * const AVMediaTypeAudio` 定数
/// （mic 権限確認は camera と同じ `AVCaptureDevice` クラスを使う。設計文書6章）。
extern "c" const AVMediaTypeAudio: objc.Id;

pub const capture = struct {
    /// `kAudioUnitProperty_MaximumFramesPerSlice` の query に失敗した場合のフォールバック上限
    /// （scratch バッファのサイズ決定用。実用上十分に大きい値）。
    const MAX_FRAMES_FALLBACK: u32 = 4096;

    /// mic capture callback に渡される `AudioInFrame` を受け取る関数ポインタ型。**RT スレッド
    /// （CoreAudio 管理）で呼ばれる**: malloc/lock/IO/panic をしてはならない。
    pub const CaptureCallback = *const fn (frame: types.AudioInFrame, userdata: ?*anyopaque) void;

    /// 要求設定（あくまでヒント）。実効値は `open()` 後に `device.config()` で取得する。
    pub const Config = struct {
        device_id: ?[]const u8 = null, // MVP 未使用（既定入力デバイス固定）
        sample_rate: u32 = 48000,
        channels: u32 = 1,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque = null,
    };

    /// `open()` がデバイスから query した実効値。
    pub const EffectiveConfig = struct {
        sample_rate: u32,
        channels: u32,
        max_frames_per_slice: u32,
    };

    /// RT スレッドの callback に安定アドレスで渡すための状態（出力側 `State` と同型の方針）。
    const CState = struct {
        unit: c.AudioUnit,
        capture_callback: CaptureCallback,
        userdata: ?*anyopaque,
        effective: capture.EffectiveConfig,
        running: bool,
        allocator: std.mem.Allocator,
        scratch: []f32, // max_frames_per_slice*channels の interleaved 固定バッファ（open 時のみ確保）
    };

    pub const CaptureDevice = struct {
        state: *CState,

        pub fn config(self: CaptureDevice) capture.EffectiveConfig {
            return self.state.effective;
        }

        pub fn start(self: CaptureDevice) types.CaptureError!void {
            if (c.AudioOutputUnitStart(self.state.unit) != 0) return error.StartFailed;
            self.state.running = true;
        }

        pub fn stop(self: CaptureDevice) void {
            if (self.state.running) {
                _ = c.AudioOutputUnitStop(self.state.unit);
                self.state.running = false;
            }
        }

        /// running なら stop → uninitialize → dispose → scratch 解放 → State 破棄。
        pub fn close(self: CaptureDevice) void {
            const state = self.state;
            if (state.running) {
                _ = c.AudioOutputUnitStop(state.unit);
                state.running = false;
            }
            _ = c.AudioUnitUninitialize(state.unit);
            _ = c.AudioComponentInstanceDispose(state.unit);
            state.allocator.free(state.scratch);
            state.allocator.destroy(state);
        }
    };

    fn mapAuthStatus(status: i64) types.PermissionState {
        return switch (status) {
            0 => .not_determined,
            1 => .restricted,
            2 => .denied,
            3 => .granted,
            else => .denied,
        };
    }

    /// マイク権限を要求し、確定した状態を返す（ブロッキング）。**未決定(.not_determined)からのみ
    /// 実際に TCC ダイアログを試みる**（camera 側と同じ判断。自動テストからは呼ばないこと。
    /// 手動検証レンジ。backlog task-49.2 参照）。
    pub fn requestPermission() types.CaptureError!types.PermissionState {
        const initial = mapAuthStatus(objc.avAuthorizationStatus(AVMediaTypeAudio));
        if (initial != .not_determined) return initial;
        const granted = objc.avRequestAccessBlocking(AVMediaTypeAudio);
        return if (granted) .granted else .denied;
    }

    /// 接続中のマイク（入力チャンネルを持つ AudioDevice）を列挙する。
    /// `kAudioHardwarePropertyDevices` で全 AudioObjectID を取得し、`kAudioDevicePropertyStreams`
    /// （scope=Input）のサイズで入力capability を判定する（サイズ0=出力専用デバイス）。
    pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
        var devices_addr = c.AudioObjectPropertyAddress{
            .mSelector = c.kAudioHardwarePropertyDevices,
            .mScope = c.kAudioObjectPropertyScopeGlobal,
            .mElement = c.kAudioObjectPropertyElementMain,
        };
        var devices_size: u32 = 0;
        if (c.AudioObjectGetPropertyDataSize(c.kAudioObjectSystemObject, &devices_addr, 0, null, &devices_size) != 0) {
            return error.OpenFailed;
        }
        const count = devices_size / @sizeOf(c.AudioObjectID);
        if (count == 0) return allocator.alloc(types.DeviceInfo, 0) catch return error.OpenFailed;

        const ids = allocator.alloc(c.AudioObjectID, count) catch return error.OpenFailed;
        defer allocator.free(ids);
        var actual_size = devices_size;
        if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &devices_addr, 0, null, &actual_size, ids.ptr) != 0) {
            return error.OpenFailed;
        }

        var default_input: c.AudioObjectID = 0;
        {
            var din_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioHardwarePropertyDefaultInputDevice,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var din_size: u32 = @sizeOf(c.AudioObjectID);
            _ = c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &din_addr, 0, null, &din_size, &default_input);
        }

        var list: std.ArrayList(types.DeviceInfo) = .empty;
        errdefer {
            for (list.items) |d| {
                allocator.free(d.id);
                allocator.free(d.name);
            }
            list.deinit(allocator);
        }

        for (ids) |dev_id| {
            var stream_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioDevicePropertyStreams,
                .mScope = c.kAudioObjectPropertyScopeInput,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var stream_size: u32 = 0;
            if (c.AudioObjectGetPropertyDataSize(dev_id, &stream_addr, 0, null, &stream_size) != 0) continue;
            if (stream_size == 0) continue; // 入力ストリーム無し＝出力専用デバイス

            var uid_ref: objc.Id = null;
            var uid_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioDevicePropertyDeviceUID,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var uid_size: u32 = @sizeOf(objc.Id);
            if (c.AudioObjectGetPropertyData(dev_id, &uid_addr, 0, null, &uid_size, &uid_ref) != 0) continue;
            defer if (uid_ref) |r| objc.msgSend(void, r, objc.sel("release"), .{});

            var name_ref: objc.Id = null;
            var name_addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioObjectPropertyName,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var name_size: u32 = @sizeOf(objc.Id);
            if (c.AudioObjectGetPropertyData(dev_id, &name_addr, 0, null, &name_size, &name_ref) != 0) continue;
            defer if (name_ref) |r| objc.msgSend(void, r, objc.sel("release"), .{});

            const uid_c: [*:0]const u8 = if (uid_ref) |r| objc.msgSend([*:0]const u8, r, objc.sel("UTF8String"), .{}) else "";
            const name_c: [*:0]const u8 = if (name_ref) |r| objc.msgSend([*:0]const u8, r, objc.sel("UTF8String"), .{}) else "";

            const id_dup = allocator.dupe(u8, std.mem.span(uid_c)) catch return error.OpenFailed;
            errdefer allocator.free(id_dup);
            const name_dup = allocator.dupe(u8, std.mem.span(name_c)) catch return error.OpenFailed;
            errdefer allocator.free(name_dup);
            list.append(allocator, .{ .id = id_dup, .name = name_dup, .kind = .audio_in, .is_default = (dev_id == default_input) }) catch return error.OpenFailed;
        }
        return list.toOwnedSlice(allocator) catch return error.OpenFailed;
    }

    /// RT スレッド（CoreAudio 管理）で呼ばれる input callback。**malloc/lock/IO/panic 禁止**
    /// （ファイル冒頭のホットパス宣言）。`AudioUnitRender` で固定確保済み `scratch` へ pull し、
    /// ユーザー `CaptureCallback` を呼ぶ。
    fn inputTrampoline(
        in_ref_con: ?*anyopaque,
        io_action_flags: ?*anyopaque,
        in_time_stamp: ?*const anyopaque,
        in_bus_number: u32,
        in_number_frames: u32,
        io_data: ?*c.AudioBufferList,
    ) callconv(.c) c.OSStatus {
        _ = io_data; // input callback では常に null（AudioUnitRender に自前バッファを渡す）
        const state: *CState = @ptrCast(@alignCast(in_ref_con orelse return 0));
        const channels = state.effective.channels;
        const frames = @min(in_number_frames, state.effective.max_frames_per_slice);

        // `open()` で `max_frames_per_slice*channels*4 <= maxInt(u32)` を検証済み（codex レビュー
        // 指摘への対応）。`frames <= max_frames_per_slice` なのでこの乗算は u32 のまま安全
        // （overflow panic の可能性が無いことが open() 時点の検証で保証されている。RT 経路で
        // 毎回 u64 へ widen する余分な演算も不要）。
        var buf_list = c.AudioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = .{.{
                .mNumberChannels = channels,
                .mDataByteSize = frames * channels * 4,
                .mData = state.scratch.ptr,
            }},
        };
        const status = c.AudioUnitRender(state.unit, io_action_flags, in_time_stamp, in_bus_number, frames, &buf_list);
        if (status != 0) return status;

        const count = @as(usize, frames) * @as(usize, channels);
        state.capture_callback(.{
            .samples = state.scratch[0..count],
            .frames = frames,
            .channels = channels,
            .sample_rate = state.effective.sample_rate,
            .timestamp_ns = 0, // MVP: AudioTimeStamp 変換は未実装（フォローアップ）
        }, state.userdata);
        return 0;
    }

    /// マイクを開く。`cfg.sample_rate`/`channels` のいずれかが 0 の場合は AudioToolbox を一切呼ばず
    /// `error.ConfigFailed`（自動テスト対象。暴走確保防止）。それ以外の経路（実際に AUHAL を
    /// 組み立てる）は実デバイス・TCC 権限に依存するため自動テストからは呼ばない
    /// （手動検証レンジ。backlog task-49.2 参照）。
    pub fn open(allocator: std.mem.Allocator, cfg: capture.Config) types.CaptureError!CaptureDevice {
        if (cfg.sample_rate == 0 or cfg.channels == 0) return error.ConfigFailed;

        // 1. AUHAL（'ahal'）component をインスタンス化
        const desc = c.AudioComponentDescription{
            .componentType = c.kAudioUnitType_Output,
            .componentSubType = c.kAudioUnitSubType_HALOutput,
            .componentManufacturer = c.kAudioUnitManufacturer_Apple,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const comp = c.AudioComponentFindNext(null, &desc) orelse return error.NoDevice;
        var unit: c.AudioUnit = null;
        if (c.AudioComponentInstanceNew(comp, &unit) != 0) return error.OpenFailed;
        errdefer _ = c.AudioComponentInstanceDispose(unit);

        // 2. 入力(element 1)を有効化、出力(element 0)を無効化
        const enable: u32 = 1;
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Input, 1, &enable, @sizeOf(u32)) != 0) {
            return error.ConfigFailed;
        }
        const disable: u32 = 0;
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_EnableIO, c.kAudioUnitScope_Output, 0, &disable, @sizeOf(u32)) != 0) {
            return error.ConfigFailed;
        }

        // 3. 既定入力デバイスを current device に設定
        var default_input: c.AudioObjectID = 0;
        {
            var addr = c.AudioObjectPropertyAddress{
                .mSelector = c.kAudioHardwarePropertyDefaultInputDevice,
                .mScope = c.kAudioObjectPropertyScopeGlobal,
                .mElement = c.kAudioObjectPropertyElementMain,
            };
            var size: u32 = @sizeOf(c.AudioObjectID);
            if (c.AudioObjectGetPropertyData(c.kAudioObjectSystemObject, &addr, 0, null, &size, &default_input) != 0 or default_input == 0) {
                return error.NoDevice;
            }
        }
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_CurrentDevice, c.kAudioUnitScope_Global, 0, &default_input, @sizeOf(c.AudioObjectID)) != 0) {
            return error.NoDevice;
        }

        // 4. クライアント側フォーマット（Float32 interleaved）を入力 element の Output scope に設定
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
        if (c.AudioUnitSetProperty(unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &asbd, @sizeOf(c.AudioStreamBasicDescription)) != 0) {
            return error.ConfigFailed;
        }

        // 5. State を確保（callback に安定アドレスで渡すため heap 確保）
        const state = allocator.create(CState) catch return error.OpenFailed;
        errdefer allocator.destroy(state);

        // 6. input callback を設定（refCon = state）
        const cb = c.AURenderCallbackStruct{
            .inputProc = inputTrampoline,
            .inputProcRefCon = state,
        };
        if (c.AudioUnitSetProperty(unit, c.kAudioOutputUnitProperty_SetInputCallback, c.kAudioUnitScope_Global, 0, &cb, @sizeOf(c.AURenderCallbackStruct)) != 0) {
            return error.ConfigFailed;
        }

        // 7. Initialize（`types.CaptureError` に InitializeFailed 相当が無いため OpenFailed に丸める。
        // 設計文書4.4「allocator 失敗を含む一般失敗」と同じ変換規約を Initialize/Query 失敗にも適用）。
        if (c.AudioUnitInitialize(unit) != 0) return error.OpenFailed;
        errdefer _ = c.AudioUnitUninitialize(unit);

        // 8. 実効値を query（同上、QueryFailed 相当が無いため OpenFailed に丸める）
        var actual = std.mem.zeroes(c.AudioStreamBasicDescription);
        var asbd_size: u32 = @sizeOf(c.AudioStreamBasicDescription);
        if (c.AudioUnitGetProperty(unit, c.kAudioUnitProperty_StreamFormat, c.kAudioUnitScope_Output, 1, &actual, &asbd_size) != 0) {
            return error.OpenFailed;
        }
        var max_frames: u32 = 0;
        var mf_size: u32 = @sizeOf(u32);
        if (c.AudioUnitGetProperty(unit, c.kAudioUnitProperty_MaximumFramesPerSlice, c.kAudioUnitScope_Global, 0, &max_frames, &mf_size) != 0 or max_frames == 0) {
            max_frames = MAX_FRAMES_FALLBACK;
        }

        const effective = capture.EffectiveConfig{
            .sample_rate = @intFromFloat(actual.mSampleRate),
            .channels = actual.mChannelsPerFrame,
            .max_frames_per_slice = max_frames,
        };
        // RT 契約の補強（codex レビュー指摘）: `max_frames_per_slice*channels*4` が u32 に収まる
        // ことを open() 側で一度だけ検証しておく。これにより inputTrampoline（RT callback）内の
        // `frames*channels*4`（frames<=max_frames_per_slice なのでこの上限で抑えられる）は
        // 検証済みの範囲に収まることが保証され、u32 のまま演算しても overflow panic が起きない
        // （callback 内で毎回 u64 へ widen する余分な演算も不要になる）。
        const max_byte_size: u64 = @as(u64, max_frames) * @as(u64, effective.channels) * 4;
        if (max_byte_size > std.math.maxInt(u32)) return error.ConfigFailed;
        const scratch = allocator.alloc(f32, @as(usize, max_frames) * @as(usize, effective.channels)) catch return error.OpenFailed;
        errdefer allocator.free(scratch);

        state.* = .{
            .unit = unit,
            .capture_callback = cfg.capture_callback,
            .userdata = cfg.userdata,
            .effective = effective,
            .running = false,
            .allocator = allocator,
            .scratch = scratch,
        };

        return .{ .state = state };
    }
};

// ========================================================================
// tests（display/実デバイス不要・OS 非依存の範囲のみ自動実行。手動テストは末尾）
// ========================================================================
const testing = std.testing;

test "mapAuthStatus: AVAuthorizationStatus の4値を正しく写像する" {
    try testing.expectEqual(types.PermissionState.not_determined, capture.mapAuthStatus(0));
    try testing.expectEqual(types.PermissionState.restricted, capture.mapAuthStatus(1));
    try testing.expectEqual(types.PermissionState.denied, capture.mapAuthStatus(2));
    try testing.expectEqual(types.PermissionState.granted, capture.mapAuthStatus(3));
    try testing.expectEqual(types.PermissionState.denied, capture.mapAuthStatus(99));
}

fn noopCaptureCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    _ = userdata;
}

test "open: sample_rate/channels=0 は AudioToolbox を呼ばず ConfigFailed" {
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .sample_rate = 0, .capture_callback = noopCaptureCallback }));
    try testing.expectError(error.ConfigFailed, capture.open(testing.allocator, .{ .channels = 0, .capture_callback = noopCaptureCallback }));
}

// ========================================================================
// 手動検証専用テスト（既定は SkipZigTest。実機で `VP_MANUAL_CAPTURE_TEST=1` を指定した時のみ
// 実マイクを開く。TCC ダイアログ・実デバイスに触れるため自動テストには含めない）
// ========================================================================
fn sleepMs(ms: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

const ManualCtx = struct {
    count: std.atomic.Value(u32) = .init(0),
};

fn manualCountingCallback(frame: types.AudioInFrame, userdata: ?*anyopaque) void {
    _ = frame;
    const ctx: *ManualCtx = @ptrCast(@alignCast(userdata.?));
    _ = ctx.count.fetchAdd(1, .monotonic);
}

test "[MANUAL] 実マイクを開いて callback が実際に呼ばれるか確認する（VP_MANUAL_CAPTURE_TEST=1 でのみ実行）" {
    if (std.c.getenv("VP_MANUAL_CAPTURE_TEST") == null) return error.SkipZigTest;
    const allocator = testing.allocator;

    const perm = try capture.requestPermission();
    std.debug.print("[manual] mic permission = {t}\n", .{perm});
    if (perm != .granted) return error.SkipZigTest;

    var ctx = ManualCtx{};
    var dev = try capture.open(allocator, .{ .sample_rate = 48000, .channels = 1, .capture_callback = manualCountingCallback, .userdata = &ctx });
    defer dev.close();
    try dev.start();
    defer dev.stop();

    sleepMs(500);
    std.debug.print("[manual] mic callback count = {d}\n", .{ctx.count.load(.monotonic)});
    try testing.expect(ctx.count.load(.monotonic) > 0);
}
