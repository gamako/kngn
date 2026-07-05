//! macOS camera backend (L1 カメラ入力プリミティブ)。AVFoundation を Objective-C ランタイム C ABI
//! （`objc_msgSend` 系。`core/objc_runtime.zig`）経由で叩く。`@cImport`/Swift は使わない
//! （AudioToolbox の C ABI 直呼びと同じ方針。AVFoundation 自体には C API が無いため libobjc の
//! C ABI をブリッジとして利用する。aarch64-darwin のみ対応。詳細根拠は `core/objc_runtime.zig`
//! 冒頭コメント参照）。
//!
//! **フレーム配送**: `AVCaptureVideoDataOutput` の sample buffer delegate（動的に生成する ObjC
//! サブクラス `VPCameraCaptureDelegate`）が capture 用 dispatch queue（GCD の専用スレッド）で
//! 呼ばれ、`CVPixelBuffer`（`kCVPixelFormatType_32BGRA` を明示要求）をそのまま canonical BGRA
//! として `capture_types.TripleBuffer` へ publish する。正規化は「ストライド吸収の行コピー」のみ
//! （`copyBgraRows`。per-pixel 演算は無い）。BGRA を明示要求しているため、ネイティブ形式
//! （YUV 等）からの変換は OS 側が内部で行う。
//!
//! **MVP の既知の簡略化**（設計文書 `docs/plans/capture-foundation-plan.md` の未確定事項）:
//! - 同時に開けるカメラは 1 台のみ（`g_active_state` がプロセス内シングルトン。複数 `open()` の
//!   同時使用はサポートしない。設計文書 2.2「複数デバイス同時 open」はスコープ外と整合）。
//! - `device.config()` の `frame_rate` は要求値をそのまま返す（実ネゴシエーション結果の反映は
//!   フォローアップ。`format` は常に `.bgra8` で正確）。
//! - `device_id` 指定でのデバイス選択は未実装（既定カメラ固定。将来 `enumerate()` の id を
//!   `open()` の `device_id` に渡す経路を追加する）。
//!
//! ホットパス宣言:
//! - **delegate callback（`sampleBufferCallback`）は capture スレッド（GCD 専用スレッド。実時間・
//!   カメラ fps 相当=既定30fps 程度）で毎フレーム呼ばれる**。区間内で malloc/lock/IO/panic 禁止
//!   （既存 audio backend の RT 契約と同じ強度）。行われるのは `CVPixelBufferLockBaseAddress`
//!   （API 契約上必須のロックで一般的な mutex ではない）+ `copyBgraRows`（行コピー）+
//!   `TripleBuffer.publish()`（alloc/lock 無し）のみ。バッファは `open()` 時に固定確保済み。
//! - **`copyBgraRows`**: フレーム毎（全画素相当）。ストライド吸収の `@memcpy` のみで per-pixel
//!   演算（ブレンド/除算）が無いため、性能規約の「全画素ループの3点セット」(SIMD/div255/
//!   clip-hoist) は対象外と判断する。既存規約が推奨する「不透明な全面塗りは @memset/一括書き込み
//!   の高速パスを用意する」という方針にむしろ合致する単純コピー。将来 BGRA 以外のネイティブ形式
//!   変換（YUV→RGB 等）を追加する場合は per-pixel 演算になるため改めて判断が必要。
//! - `enumerate`/`requestPermission`/`open`/`start`/`stop`/`close`: **初期化時 / イベント時のみ**
//!   （フレーム毎・毎サンプルではない）。

const std = @import("std");
const types = @import("capture_types");
const objc = @import("objc_runtime.zig");

// ============================================================================
// AVFoundation / CoreMedia / CoreVideo C ABI（最小サブセット）
// ============================================================================

/// AVFoundation.framework が公開する `NSString * const AVMediaTypeVideo` 定数。
extern "c" const AVMediaTypeVideo: objc.Id;

/// CoreMedia.framework: `CMSampleBufferRef` から `CVImageBufferRef`（実体は `CVPixelBufferRef`）を
/// 取り出す（C API。ObjC 不要）。
extern "c" fn CMSampleBufferGetImageBuffer(sbuf: objc.Id) objc.Id;

/// CoreVideo.framework: `CVPixelBuffer` 系 C API。
extern "c" fn CVPixelBufferLockBaseAddress(pixel_buffer: objc.Id, lock_flags: u64) i32; // CVReturn
extern "c" fn CVPixelBufferUnlockBaseAddress(pixel_buffer: objc.Id, lock_flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pixel_buffer: objc.Id) ?*anyopaque;
extern "c" fn CVPixelBufferGetBytesPerRow(pixel_buffer: objc.Id) usize;
extern "c" fn CVPixelBufferGetWidth(pixel_buffer: objc.Id) usize;
extern "c" fn CVPixelBufferGetHeight(pixel_buffer: objc.Id) usize;

/// CoreVideo.framework が公開する `NSString * const kCVPixelBufferPixelFormatTypeKey` 定数。
extern "c" const kCVPixelBufferPixelFormatTypeKey: objc.Id;

const kCVPixelBufferLock_ReadOnly: u64 = 0x0000_0001;
/// 'BGRA' の FourCharCode（数値定数。NSString ではない）。
const kCVPixelFormatType_32BGRA: u32 = 0x4247_5241;

/// libdispatch（GCD。libSystem 内蔵。frameworkリンク不要）。
extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_release(object: ?*anyopaque) void;
extern "c" fn dispatch_sync_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

// ============================================================================
// 正規化: ストライド吸収の行コピー（フレーム毎。ホットパス宣言はファイル冒頭）
// ============================================================================

/// `src`（`src_bytes_per_row` でパディングされた BGRA8 ネイティブバッファ）から `dst`
/// （`dst_stride` pixel 単位で確保済みの固定バッファ）へ、`width`x`height` 分を行単位でコピーする。
/// per-pixel 演算は無い単純な `@memcpy`（性能規約の適用外。理由はファイル冒頭のホットパス宣言）。
pub fn copyBgraRows(
    dst: []u32,
    dst_stride: u32,
    src: [*]const u8,
    src_bytes_per_row: usize,
    width: u32,
    height: u32,
) void {
    const row_bytes = @as(usize, width) * 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_row = src[@as(usize, y) * src_bytes_per_row ..][0..row_bytes];
        const dst_row_start = @as(usize, y) * dst_stride;
        const dst_row = std.mem.sliceAsBytes(dst[dst_row_start..][0..width]);
        @memcpy(dst_row, src_row);
    }
}

// ============================================================================
// 権限
// ============================================================================

fn mapAuthStatus(status: i64) types.PermissionState {
    return switch (status) {
        0 => .not_determined,
        1 => .restricted,
        2 => .denied,
        3 => .granted,
        else => .denied,
    };
}

/// カメラ権限を要求し、確定した状態を返す（ブロッキング）。**未決定(.not_determined)からのみ
/// 実際に TCC ダイアログを試みる**（既に granted/denied/restricted な場合は再ダイアログを出さず
/// 即座にその状態を返す。自動テストからは呼ばないこと。手動検証レンジ。backlog task-49.2 参照）。
pub fn requestPermission() types.CaptureError!types.PermissionState {
    const initial = mapAuthStatus(objc.avAuthorizationStatus(AVMediaTypeVideo));
    if (initial != .not_determined) return initial;
    const granted = objc.avRequestAccessBlocking(AVMediaTypeVideo);
    return if (granted) .granted else .denied;
}

// ============================================================================
// 列挙
// ============================================================================

/// 接続中のカメラを列挙する。`AVCaptureDevice.devicesWithMediaType:`（列挙自体は TCC 権限を
/// 要求しない。実機での動作確認は手動検証レンジ）。
pub fn enumerate(allocator: std.mem.Allocator) types.CaptureError![]types.DeviceInfo {
    const cls = objc.getClass("AVCaptureDevice");
    const devices_ns = objc.msgSend(objc.Id, cls, objc.sel("devicesWithMediaType:"), .{AVMediaTypeVideo});
    if (devices_ns == null) return error.NoDevice;
    const count: i64 = objc.msgSend(i64, devices_ns, objc.sel("count"), .{});
    if (count <= 0) return allocator.alloc(types.DeviceInfo, 0) catch return error.OpenFailed;

    var list: std.ArrayList(types.DeviceInfo) = .empty;
    errdefer {
        for (list.items) |d| {
            allocator.free(d.id);
            allocator.free(d.name);
        }
        list.deinit(allocator);
    }
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        const dev = objc.msgSend(objc.Id, devices_ns, objc.sel("objectAtIndex:"), .{@as(usize, @intCast(i))});
        const name_ns = objc.msgSend(objc.Id, dev, objc.sel("localizedName"), .{});
        const uid_ns = objc.msgSend(objc.Id, dev, objc.sel("uniqueID"), .{});
        const name_c = objc.msgSend([*:0]const u8, name_ns, objc.sel("UTF8String"), .{});
        const uid_c = objc.msgSend([*:0]const u8, uid_ns, objc.sel("UTF8String"), .{});
        const name_dup = allocator.dupe(u8, std.mem.span(name_c)) catch return error.OpenFailed;
        errdefer allocator.free(name_dup);
        const id_dup = allocator.dupe(u8, std.mem.span(uid_c)) catch return error.OpenFailed;
        errdefer allocator.free(id_dup);
        list.append(allocator, .{ .id = id_dup, .name = name_dup, .kind = .video_in, .is_default = (i == 0) }) catch return error.OpenFailed;
    }
    return list.toOwnedSlice(allocator) catch return error.OpenFailed;
}

// ============================================================================
// 動的 delegate クラス（sample buffer 受信）
// ============================================================================

var delegate_class: objc.Class = null;

fn noopDrain(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

/// capture スレッド（GCD queue）で呼ばれる。**RT 契約区間**: malloc/lock/IO/panic 禁止
/// （ファイル冒頭のホットパス宣言）。`g_active_state` は atomic 経由でのみ読む
/// （`close()` が別スレッド=main から null 化するため）。
fn sampleBufferCallback(self_: objc.Id, _cmd: objc.SEL, output: objc.Id, sample_buffer: objc.Id, connection: objc.Id) callconv(.c) void {
    _ = self_;
    _ = _cmd;
    _ = output;
    _ = connection;
    const state = g_active_state.load(.acquire) orelse return;

    const image_buf = CMSampleBufferGetImageBuffer(sample_buffer) orelse return;
    if (CVPixelBufferLockBaseAddress(image_buf, kCVPixelBufferLock_ReadOnly) != 0) return;
    defer _ = CVPixelBufferUnlockBaseAddress(image_buf, kCVPixelBufferLock_ReadOnly);

    const base = CVPixelBufferGetBaseAddress(image_buf) orelse return;
    const bytes_per_row = CVPixelBufferGetBytesPerRow(image_buf);
    const src_w: usize = CVPixelBufferGetWidth(image_buf);
    const src_h: usize = CVPixelBufferGetHeight(image_buf);
    const w: u32 = @intCast(@min(src_w, state.width));
    const h: u32 = @intCast(@min(src_h, state.height));

    const slot = state.triple.write_idx & 0x03;
    const dst = state.slot_pixels[slot];
    copyBgraRows(dst, state.width, @ptrCast(base), bytes_per_row, w, h);

    const frame_index = state.frame_counter.fetchAdd(1, .monotonic);
    state.triple.publish(.{
        .pixels = dst,
        .width = state.width,
        .height = state.height,
        .stride = state.width,
        .format = .bgra8,
        .timestamp_ns = 0, // MVP: CMSampleBuffer の PTS 変換は未実装（フォローアップ）
        .frame_index = frame_index,
    });
}

/// `VPCameraCaptureDelegate`（NSObject サブクラス。`captureOutput:didOutputSampleBuffer:
/// fromConnection:` のみ実装）を初回のみ動的生成する。プロセス内で1回だけ登録される
/// （`objc_allocateClassPair` は同名クラスが既にあれば null を返すため、その場合は
/// `objc_getClass` で既存クラスを拾う防御を入れる）。
fn ensureDelegateClass() objc.Class {
    if (delegate_class) |c| return c;
    const superclass = objc.getClass("NSObject");
    const cls = objc.objc_allocateClassPair(superclass, "VPCameraCaptureDelegate", 0) orelse {
        delegate_class = objc.getClass("VPCameraCaptureDelegate");
        return delegate_class;
    };
    const sel_name = objc.sel("captureOutput:didOutputSampleBuffer:fromConnection:");
    _ = objc.class_addMethod(cls, sel_name, @ptrCast(&sampleBufferCallback), "v@:@@@");
    // 実行時の意味論には影響しない（setSampleBufferDelegate:queue: 自体は raw runtime 経由なら
    // プロトコル適合を検査しない）が、`conformsToProtocol:`/introspection の正しさのため宣言する。
    if (objc.objc_getProtocol("AVCaptureVideoDataOutputSampleBufferDelegate")) |proto| {
        _ = objc.class_addProtocol(cls, proto);
    }
    objc.objc_registerClassPair(cls);
    delegate_class = cls;
    return cls;
}

// ============================================================================
// 公開型
// ============================================================================

pub const MAX_VIDEO_DIM: u32 = 4096;

/// 要求設定（あくまでヒント）。実効値は `open()` 後に `device.config()` で取得する。
pub const Config = struct {
    device_id: ?[]const u8 = null, // MVP 未使用（既定カメラ固定。将来デバイス選択に対応）
    width: u32 = 640,
    height: u32 = 480,
    frame_rate: u32 = 30,
};

/// `open()` が返す実効値。
pub const EffectiveConfig = struct {
    width: u32,
    height: u32,
    frame_rate: u32,
    format: types.PixelFormat = .bgra8,
};

const State = struct {
    session: objc.Id,
    device_input: objc.Id,
    output: objc.Id,
    delegate: objc.Id,
    queue: ?*anyopaque,
    width: u32,
    height: u32,
    frame_rate: u32,
    running: bool,
    allocator: std.mem.Allocator,
    triple: types.TripleBuffer(types.VideoFrame),
    frame_counter: std.atomic.Value(u64),
    slot_pixels: [3][]u32, // TripleBuffer の3スロットそれぞれに対応する物理ピクセルバッファ
};

/// プロセス内シングルトン（MVP の簡略化。ファイル冒頭コメント参照）。capture スレッドと main
/// スレッドの双方から触るため atomic。
var g_active_state: std.atomic.Value(?*State) = .init(null);

pub const VideoDevice = struct {
    state: *State,

    pub fn config(self: VideoDevice) EffectiveConfig {
        return .{
            .width = self.state.width,
            .height = self.state.height,
            .frame_rate = self.state.frame_rate,
            .format = .bgra8,
        };
    }

    pub fn start(self: VideoDevice) types.CaptureError!void {
        if (self.state.running) return;
        objc.msgSend(void, self.state.session, objc.sel("startRunning"), .{});
        self.state.running = true;
    }

    pub fn stop(self: VideoDevice) void {
        if (!self.state.running) return;
        objc.msgSend(void, self.state.session, objc.sel("stopRunning"), .{});
        self.state.running = false;
    }

    /// stop → **delegate を output から detach**（`setSampleBufferDelegate:queue:` に
    /// nil,nil。以後 output は新規 callback を一切 enqueue しない）→ `g_active_state` を null 化
    /// → capture queue を drain（detach 前に**既に**enqueue 済みだった callback の完了を待つ。
    /// 同一 serial queue 上の `dispatch_sync_f` no-op で保証）→ ObjC オブジェクト解放 →
    /// 物理バッファ解放 → State 破棄。
    ///
    /// detach を drain より先に行うのが重要（codex レビュー指摘）: `g_active_state` の null 化と
    /// drain だけでは「drain 後に AVFoundation が新しい callback を enqueue する」余地が残り、
    /// 解放済み delegate への use-after-free になり得る。delegate を先に外せばそのリスクが無い。
    pub fn close(self: VideoDevice) void {
        const state = self.state;
        if (state.running) {
            objc.msgSend(void, state.session, objc.sel("stopRunning"), .{});
            state.running = false;
        }
        objc.msgSend(void, state.output, objc.sel("setSampleBufferDelegate:queue:"), .{ @as(objc.Id, null), @as(?*anyopaque, null) });
        g_active_state.store(null, .release);
        dispatch_sync_f(state.queue, null, noopDrain);

        objc.msgSend(void, state.output, objc.sel("release"), .{});
        objc.msgSend(void, state.device_input, objc.sel("release"), .{});
        objc.msgSend(void, state.session, objc.sel("release"), .{});
        objc.msgSend(void, state.delegate, objc.sel("release"), .{});
        dispatch_release(state.queue);

        for (state.slot_pixels) |buf| state.allocator.free(buf);
        state.allocator.destroy(state);
    }

    /// 直近フレームを非ブロッキングで取得する。1度も publish されていなければ `null`
    /// （`open`直後/capture開始前。設計文書3.2）。
    pub fn pollLatestFrame(self: VideoDevice) ?types.VideoFrame {
        if (self.state.frame_counter.load(.monotonic) == 0) return null;
        return self.state.triple.acquire().*;
    }
};

/// カメラを開く。`cfg.width`/`height`/`frame_rate` がいずれか 0、または `MAX_VIDEO_DIM` を超える
/// 場合は AVFoundation を一切呼ばず `error.ConfigFailed`（自動テスト対象。暴走確保防止）。
/// それ以外の経路（実際に `AVCaptureSession` を組み立てる）は実デバイス・TCC 権限に依存するため
/// 自動テストからは呼ばない（手動検証レンジ。backlog task-49.2 参照）。
///
/// **同時に開けるカメラは 1 台のみ**（`g_active_state` プロセス内シングルトン。codex レビュー
/// 指摘: 2 度目の `open()` を素通しすると、先に開いていた device の callback/`close()` が
/// 後発の `State` を巻き込んで壊す）。既に active な場合は AVFoundation を呼ばず即
/// `error.OpenFailed`（fail-fast チェック）。関数末尾でも `cmpxchgStrong` で再確認し、
/// 2並行 `open()` の race を防ぐ（負けた側はここまでに確保した全リソースを errdefer で解放する）。
pub fn open(allocator: std.mem.Allocator, cfg: Config) types.CaptureError!VideoDevice {
    if (cfg.width == 0 or cfg.height == 0 or cfg.frame_rate == 0) return error.ConfigFailed;
    if (cfg.width > MAX_VIDEO_DIM or cfg.height > MAX_VIDEO_DIM) return error.ConfigFailed;
    if (g_active_state.load(.acquire) != null) return error.OpenFailed; // fail-fast（既に1台 open 中）

    const device = objc.msgSend(objc.Id, objc.getClass("AVCaptureDevice"), objc.sel("defaultDeviceWithMediaType:"), .{AVMediaTypeVideo});
    if (device == null) return error.NoDevice;

    const device_input = objc.msgSend(objc.Id, objc.getClass("AVCaptureDeviceInput"), objc.sel("deviceInputWithDevice:error:"), .{ device, @as(objc.Id, null) });
    if (device_input == null) return error.OpenFailed;
    _ = objc.msgSend(objc.Id, device_input, objc.sel("retain"), .{});
    errdefer objc.msgSend(void, device_input, objc.sel("release"), .{});

    const session = objc.msgSend(objc.Id, objc.msgSend(objc.Id, objc.getClass("AVCaptureSession"), objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (session == null) return error.OpenFailed;
    errdefer objc.msgSend(void, session, objc.sel("release"), .{});
    objc.msgSend(void, session, objc.sel("addInput:"), .{device_input});

    const output = objc.msgSend(objc.Id, objc.msgSend(objc.Id, objc.getClass("AVCaptureVideoDataOutput"), objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (output == null) return error.OpenFailed;
    errdefer objc.msgSend(void, output, objc.sel("release"), .{});

    // videoSettings = { kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA(数値) }
    const dict = objc.msgSend(objc.Id, objc.msgSend(objc.Id, objc.getClass("NSMutableDictionary"), objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (dict == null) return error.OpenFailed;
    const num = objc.msgSend(objc.Id, objc.getClass("NSNumber"), objc.sel("numberWithUnsignedInt:"), .{@as(u32, kCVPixelFormatType_32BGRA)});
    objc.msgSend(void, dict, objc.sel("setObject:forKey:"), .{ num, kCVPixelBufferPixelFormatTypeKey });
    objc.msgSend(void, output, objc.sel("setVideoSettings:"), .{dict});
    objc.msgSend(void, dict, objc.sel("release"), .{});
    objc.msgSend(void, output, objc.sel("setAlwaysDiscardsLateVideoFrames:"), .{true});

    const queue = dispatch_queue_create("video-proto.camera.capture", null);
    if (queue == null) return error.OpenFailed;
    errdefer dispatch_release(queue);

    const delegate_cls = ensureDelegateClass();
    const delegate = objc.msgSend(objc.Id, objc.msgSend(objc.Id, delegate_cls, objc.sel("alloc"), .{}), objc.sel("init"), .{});
    if (delegate == null) return error.OpenFailed;
    errdefer objc.msgSend(void, delegate, objc.sel("release"), .{});

    objc.msgSend(void, output, objc.sel("setSampleBufferDelegate:queue:"), .{ delegate, queue });
    objc.msgSend(void, session, objc.sel("addOutput:"), .{output});

    const n = @as(usize, cfg.width) * @as(usize, cfg.height);
    var slot_pixels: [3][]u32 = undefined;
    var allocated: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < allocated) : (i += 1) allocator.free(slot_pixels[i]);
    }
    while (allocated < 3) : (allocated += 1) {
        slot_pixels[allocated] = allocator.alloc(u32, n) catch return error.OpenFailed;
        @memset(slot_pixels[allocated], 0xFF00_0000); // 未 publish 時は不透明黒（fb 初期値と対称）
    }

    const state = allocator.create(State) catch return error.OpenFailed;
    errdefer allocator.destroy(state);
    var triple = types.TripleBuffer(types.VideoFrame).init(.{
        .pixels = slot_pixels[0],
        .width = cfg.width,
        .height = cfg.height,
        .stride = cfg.width,
        .format = .bgra8,
        .timestamp_ns = 0,
        .frame_index = 0,
    });
    // init() は3スロット全てに同じ initial 値を複製するため、各スロットが対応する物理バッファを
    // 指すよう明示的に固定し直す（設計文書3.2「3枚の物理ピクセルバッファに固定」を open() 直後
    // から満たす）。
    triple.bufs[0].pixels = slot_pixels[0];
    triple.bufs[1].pixels = slot_pixels[1];
    triple.bufs[2].pixels = slot_pixels[2];

    state.* = .{
        .session = session,
        .device_input = device_input,
        .output = output,
        .delegate = delegate,
        .queue = queue,
        .width = cfg.width,
        .height = cfg.height,
        .frame_rate = cfg.frame_rate,
        .running = false,
        .allocator = allocator,
        .triple = triple,
        .frame_counter = .init(0),
        .slot_pixels = slot_pixels,
    };

    // cmpxchg で再確認（2並行 open() の race に備える。fail-fast チェック後にもう1本の open() が
    // 先に成立していたら、ここまでに確保した全リソースを errdefer で解放して失敗させる）。
    if (g_active_state.cmpxchgStrong(null, state, .acq_rel, .acquire) != null) {
        return error.OpenFailed;
    }
    return .{ .state = state };
}

// ============================================================================
// tests（display/実デバイス不要・OS 非依存の範囲のみ自動実行。手動テストは末尾）
// ============================================================================
const testing = std.testing;

test "copyBgraRows: パディング付き source から stride 吸収で正しく抽出できる" {
    const width: u32 = 3;
    const height: u32 = 2;
    const bytes_per_row: usize = 16; // width*4=12 + 4 byte padding
    const row0 = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0xFF, 0xFF, 0xFF, 0xFF };
    const row1 = [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0xFF, 0xFF, 0xFF, 0xFF };
    var src: [32]u8 = undefined;
    @memcpy(src[0..16], &row0);
    @memcpy(src[16..32], &row1);

    var dst: [6]u32 = undefined; // stride == width == 3（パディング無し）
    copyBgraRows(&dst, 3, &src, bytes_per_row, width, height);

    var expected: [24]u8 = undefined;
    @memcpy(expected[0..12], row0[0..12]);
    @memcpy(expected[12..24], row1[0..12]);
    try testing.expectEqualSlices(u8, &expected, std.mem.sliceAsBytes(dst[0..]));
}

test "copyBgraRows: dst_stride > width でも正しい列に書く（dst 側のパディングも吸収）" {
    const width: u32 = 2;
    const height: u32 = 2;
    const bytes_per_row: usize = 8; // width*4=8, パディング無し source
    const row0 = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const row1 = [_]u8{ 9, 10, 11, 12, 13, 14, 15, 16 };
    var src: [16]u8 = undefined;
    @memcpy(src[0..8], &row0);
    @memcpy(src[8..16], &row1);

    var dst = [_]u32{0xDEADBEEF} ** 8; // stride=4 (width=2 + padding 2px)
    copyBgraRows(&dst, 4, &src, bytes_per_row, width, height);

    const dst_bytes = std.mem.sliceAsBytes(dst[0..]);
    try testing.expectEqualSlices(u8, &row0, dst_bytes[0..8]); // row0 の実データ
    try testing.expectEqual(@as(u32, 0xDEADBEEF), dst[2]); // row0 のパディング列は未変更
    try testing.expectEqual(@as(u32, 0xDEADBEEF), dst[3]);
    try testing.expectEqualSlices(u8, &row1, dst_bytes[16..24]); // row1 (dst_stride=4 の位置から)
}

test "mapAuthStatus: AVAuthorizationStatus の4値を正しく写像する" {
    try testing.expectEqual(types.PermissionState.not_determined, mapAuthStatus(0));
    try testing.expectEqual(types.PermissionState.restricted, mapAuthStatus(1));
    try testing.expectEqual(types.PermissionState.denied, mapAuthStatus(2));
    try testing.expectEqual(types.PermissionState.granted, mapAuthStatus(3));
    try testing.expectEqual(types.PermissionState.denied, mapAuthStatus(99)); // 未知値は安全側(denied)
}

test "open: width/height/frame_rate=0 は AVFoundation を呼ばず ConfigFailed" {
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 0, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = 0, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = 8, .frame_rate = 0 }));
}

test "open: 解像度上限超過は AVFoundation を呼ばず ConfigFailed" {
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = MAX_VIDEO_DIM + 1, .height = 8, .frame_rate = 30 }));
    try testing.expectError(error.ConfigFailed, open(testing.allocator, .{ .width = 8, .height = MAX_VIDEO_DIM + 1, .frame_rate = 30 }));
}

// ============================================================================
// 手動検証専用テスト（既定は SkipZigTest。実機で `VP_MANUAL_CAPTURE_TEST=1` を指定した時のみ
// 実カメラを開く。TCC ダイアログ・実デバイスに触れるため自動テストには含めない）
// ============================================================================

fn sleepMs(ms: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

test "[MANUAL] 実カメラを開いて数フレーム受信できるか確認する（VP_MANUAL_CAPTURE_TEST=1 でのみ実行）" {
    if (std.c.getenv("VP_MANUAL_CAPTURE_TEST") == null) return error.SkipZigTest;
    const allocator = testing.allocator;

    const perm = try requestPermission();
    std.debug.print("[manual] camera permission = {t}\n", .{perm});
    if (perm != .granted) return error.SkipZigTest;

    var dev = try open(allocator, .{ .width = 320, .height = 240, .frame_rate = 30 });
    defer dev.close();
    try dev.start();
    defer dev.stop();

    var got = false;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        sleepMs(50);
        if (dev.pollLatestFrame()) |f| {
            std.debug.print("[manual] got frame {d}x{d} frame_index={d}\n", .{ f.width, f.height, f.frame_index });
            got = true;
            break;
        }
    }
    try testing.expect(got);
}
