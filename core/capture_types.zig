//! capture 入力基盤の共有型（control plane 共通規約 + data plane 型）単一ソース（TASK-49.1）。
//!
//! マイク（`core/audio.zig` の capture 拡張）/ カメラ（`core/camera.zig`）の facade がここの型を
//! 共用することで「同じ動詞概念・同じエラー分類・同じ型 shape」という control plane 統一を実現する
//! （`CaptureDevice` 的な統一 union / vtable は作らない。命名は host module の事情で異なってよいが
//! 意味論は揃える）。設計の正は `docs/plans/capture-foundation-plan.md`。
//!
//! `capture_types` は `camera` module と `audio` module の**両方**から named module として
//! `link()` される（platform_types.zig と同じ理由: Zig の相対 import は module ごとに別インスタンス
//! の型になるため、型同一性が要る共有型は named module 化が必須。詳細は設計文書 8章）。
//!
//! 依存: std のみ（platform_types.zig と同じ type-only module。ADR-007 で libs からの参照も許可）。
//!
//! ホットパス宣言: このファイル自体は型定義 + `TripleBuffer(T)` の publish/acquire のみで、
//! フレーム毎(全画素)/RT(毎サンプル)の**ループは書かない**。ただし `TripleBuffer(T)` は
//! カメラの capture スレッド→main のフレーム配送（capture スレッド側はフレーム毎に `publish()` を
//! 1回呼ぶ想定）で使われるため、`publish`/`acquire` 自体は O(1)・alloc/lock 無しを維持する
//! （設計文書 3.2 の RT/capture スレッド制約）。

const std = @import("std");

// ============================================================================
// control plane 共通型
// ============================================================================

/// capture デバイスの種別（mic / camera）。
pub const DeviceKind = enum { audio_in, video_in };

/// デバイス列挙結果 1 件。`id`/`name` は `enumerate()` を呼んだ allocator で確保され、
/// 呼び出し側が `freeDeviceList()` で解放する（4.4 節）。
pub const DeviceInfo = struct {
    id: []const u8,
    name: []const u8,
    kind: DeviceKind,
    is_default: bool = false,
};

/// `enumerate()` が返した `[]DeviceInfo` を対称に解放する（id/name を個別に free → スライスを free）。
/// 49.2〜.4 のどの backend も `enumerate()` をこの allocator 契約で実装する。
pub fn freeDeviceList(allocator: std.mem.Allocator, devices: []DeviceInfo) void {
    for (devices) |d| {
        allocator.free(d.id);
        allocator.free(d.name);
    }
    allocator.free(devices);
}

/// 権限状態（mic/camera 共通分類）。
/// - `denied`: ユーザーが明示的に拒否した／設定アプリで変更可能。
/// - `restricted`: MDM 等のポリシーでそもそも変更不能（macOS TCC の `authorizationStatus` が
///   実際にこの4値を返す）。UI が「設定を開くよう促す」か「変更不能と表示する」かを分岐する材料。
pub const PermissionState = enum { not_determined, granted, denied, restricted };

/// mic/camera facade が共用する error set（control plane 統一の実体）。
/// allocator 失敗（`enumerate`/`open` 内部の alloc）は `OpenFailed` に丸める（既存出力 backend の
/// `allocator.create(State) catch return error.OpenFailed;` と同じ変換規約。`OutOfMemory` を
/// union しない。単一 error set の単純さとコードベース内の一貫性を優先するトレードオフ）。
pub const CaptureError = error{
    PermissionDenied, // 権限が明示的に拒否/制限されている
    NoDevice, // 対象デバイスが存在しない
    DeviceLost, // 動作中にデバイスが切断された
    ConfigFailed, // フォーマット折衝失敗
    Unsupported, // 未実装 backend（TASK-49.1 の全 OS stub はこれを返す）/ OS 非対応機能
    OpenFailed, // デバイス初期化失敗（allocator 失敗を含む一般失敗）
    StartFailed, // start() 失敗
};

// ============================================================================
// data plane: audio in (PCM)
// ============================================================================

/// mic capture callback に渡す 1 チャンク（読み取り専用ビュー）。
/// 出力 `RenderCallback` の「書き込み先バッファを渡す」に対し、入力は「完成品を渡す」非対称。
/// `samples` は callback 実行中のみ有効（出力 `RenderCallback` の `buf` と同じ生存規約）。
///
/// `CaptureCallback`（callback 関数ポインタ型）・`Config`/`EffectiveConfig` は capture_types には
/// 置かず、mic 側 backend ファイル（`core/audio_capture_stub.zig`）に置く（出力の `RenderCallback`/
/// `Config` が `audio_macos.zig` 等の backend ファイルに置かれているのと同じ配置規約）。
pub const AudioInFrame = struct {
    samples: []const f32, // interleaved
    frames: u32,
    channels: u32,
    sample_rate: u32,
    timestamp_ns: u64,
};

// ============================================================================
// data plane: video (BGRA フレーム)
// ============================================================================

/// capture フレームの pixel format。配送は常に canonical BGRA に正規化する（MVP は `bgra8` のみ）。
/// 正規化（YUY2/NV12 等ネイティブ形式 → BGRA 変換）は backend の責務（TASK-49.2〜.4）。
/// enum のまま残すのは将来「ネイティブ形式を診断目的で申告する」拡張の余地のため。
pub const PixelFormat = enum { bgra8 };

/// camera フレーム 1 枚。`pixels` は canonical BGRA（`core/platform.zig` の framebuffer と同一表現:
/// u32 `0xAARRGGBB`）。`VideoDevice.pollLatestFrame()` が返す view の生存規約は「次に
/// `pollLatestFrame()` を呼ぶまで有効」（`TripleBuffer` の `front` スロット契約）。
pub const VideoFrame = struct {
    pixels: []const u32, // row-major, stride 単位（1 要素 = 1 pixel）
    width: u32,
    height: u32,
    stride: u32, // 1 行あたりの pixel 数（>= width。native padding 吸収用）
    format: PixelFormat = .bgra8,
    timestamp_ns: u64,
    frame_index: u64,
};

// ============================================================================
// video フレーム latest-wins 受け渡し（capture スレッド→main の固定3スロット）
// ============================================================================

/// 単一 atomic `shared` による 3 スロット SPSC（producer が read slot を絶対に書かない設計）。
/// `libs/modular` の `Mailbox(T)` と同型だが、core は libs に依存できない（ADR-007 R2）ため
/// この core 内に自己完結コピーを持つ（`core/audio_null.zig` が `platform.sleep()` 相当を
/// 複製しているのと同じ方針。層をまたいだ再輸入をしない既存規約の踏襲）。
///
/// `T` は **値コピーで publish される POD/view 型のみ**を想定する。`deinit` が要る所有型
/// （確保したメモリを自分で持つ型）を `T` に入れない。`VideoFrame` は `pixels: []const u32` を
/// 外部の固定バッファへの view として持つだけなので、この契約を満たす。
///
/// producer（capture スレッド）は `publish()` のみ・never block。consumer（main）は `acquire()` の
/// み。3 index（`write_idx`/`read_idx`/`shared` 下位2bit）は常に `{0,1,2}` の置換であり、producer は
/// 現在 read/ready のスロットを絶対に書かない（テストで不変条件を固定する）。
pub fn TripleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const FRESH: u8 = 0x80;
        const IDX_MASK: u8 = 0x03;

        bufs: [3]T,
        shared: std.atomic.Value(u8),
        write_idx: u8, // producer(capture thread)-private
        read_idx: u8, // consumer(main)-private

        pub fn init(initial: T) Self {
            return .{
                .bufs = .{ initial, initial, initial },
                .shared = .init(2), // slot2 published(no fresh) / write=0 / read=1
                .write_idx = 0,
                .read_idx = 1,
            };
        }

        /// producer（capture スレッド）: private write slot に書いてから ready と交換。never block。
        pub fn publish(self: *Self, value: T) void {
            self.bufs[self.write_idx] = value;
            const new: u8 = self.write_idx | FRESH;
            const old = self.shared.swap(new, .acq_rel);
            self.write_idx = old & IDX_MASK;
        }

        /// consumer（main）: fresh があれば read slot を ready と交換して最新を latch、無ければ
        /// 直前の view を維持（latest-wins・取りこぼし可）。
        pub fn acquire(self: *Self) *const T {
            const s = self.shared.load(.acquire);
            if (s & FRESH != 0) {
                const old = self.shared.swap(self.read_idx, .acq_rel);
                self.read_idx = old & IDX_MASK;
            }
            return &self.bufs[self.read_idx];
        }

        /// テスト用: 3 index が {0,1,2} の置換であることを確認する（不変条件）。
        pub fn indicesArePermutation(self: *const Self) bool {
            const a = self.write_idx & IDX_MASK;
            const b = self.read_idx & IDX_MASK;
            const c = self.shared.load(.monotonic) & IDX_MASK;
            return a != b and b != c and a != c and a < 3 and b < 3 and c < 3;
        }
    };
}

// ============================================================================
// tests
// ============================================================================
const testing = std.testing;

test "DeviceInfo/freeDeviceList: allocator 契約どおり確保・解放できる（testing.allocator でリーク検出）" {
    const allocator = testing.allocator;
    var devices = try allocator.alloc(DeviceInfo, 2);
    devices[0] = .{ .id = try allocator.dupe(u8, "dev-0"), .name = try allocator.dupe(u8, "Built-in Mic"), .kind = .audio_in, .is_default = true };
    devices[1] = .{ .id = try allocator.dupe(u8, "dev-1"), .name = try allocator.dupe(u8, "USB Cam"), .kind = .video_in };
    freeDeviceList(allocator, devices);
    // testing.allocator は関数末尾でリーク検出するため、ここまで到達すれば解放は正しい。
}

test "CaptureError: 全メンバが capture_types 単一ソースに揃っている（存在チェック）" {
    const a: CaptureError = error.PermissionDenied;
    const b: CaptureError = error.NoDevice;
    const c: CaptureError = error.DeviceLost;
    const d: CaptureError = error.ConfigFailed;
    const e: CaptureError = error.Unsupported;
    const f: CaptureError = error.OpenFailed;
    const g: CaptureError = error.StartFailed;
    try testing.expectError(error.PermissionDenied, @as(CaptureError!void, a));
    try testing.expectError(error.NoDevice, @as(CaptureError!void, b));
    try testing.expectError(error.DeviceLost, @as(CaptureError!void, c));
    try testing.expectError(error.ConfigFailed, @as(CaptureError!void, d));
    try testing.expectError(error.Unsupported, @as(CaptureError!void, e));
    try testing.expectError(error.OpenFailed, @as(CaptureError!void, f));
    try testing.expectError(error.StartFailed, @as(CaptureError!void, g));
}

test "PermissionState: 4値であることを固定（not_determined/granted/denied/restrictedを区別する設計）" {
    try testing.expectEqual(@as(usize, 4), @typeInfo(PermissionState).@"enum".fields.len);
}

test "AudioInFrame/VideoFrame: POD であること（値コピーで扱える。allocator 不要）" {
    const frame = AudioInFrame{ .samples = &.{}, .frames = 0, .channels = 1, .sample_rate = 48000, .timestamp_ns = 0 };
    const copy = frame;
    try testing.expectEqual(frame.sample_rate, copy.sample_rate);

    const vf = VideoFrame{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0, .timestamp_ns = 0, .frame_index = 0 };
    const vf_copy = vf;
    try testing.expectEqual(vf.format, vf_copy.format);
}

test "TripleBuffer: publish 前は init 直後の値が見える" {
    var tb = TripleBuffer(u32).init(42);
    try testing.expectEqual(@as(u32, 42), tb.acquire().*);
}

test "TripleBuffer: publish -> acquire で最新値が見える（latest-wins round-trip）" {
    var tb = TripleBuffer(u32).init(0);
    tb.publish(1);
    try testing.expectEqual(@as(u32, 1), tb.acquire().*);
    tb.publish(2);
    tb.publish(3);
    // acquire を挟まず複数回 publish しても、次の acquire では最新値のみが見える（取りこぼし可）。
    try testing.expectEqual(@as(u32, 3), tb.acquire().*);
}

test "TripleBuffer: 未 publish の acquire は直前の view を維持する（fresh 無しなら再取得しない）" {
    var tb = TripleBuffer(u32).init(7);
    _ = tb.acquire();
    // publish していないので何度 acquire しても同じ値。
    try testing.expectEqual(@as(u32, 7), tb.acquire().*);
    try testing.expectEqual(@as(u32, 7), tb.acquire().*);
}

test "TripleBuffer: 3 index は常に {0,1,2} の置換（producer は read slot を書かない不変条件）" {
    var tb = TripleBuffer(u32).init(0);
    try testing.expect(tb.indicesArePermutation());
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        tb.publish(i);
        try testing.expect(tb.indicesArePermutation());
        if (i % 3 == 0) {
            _ = tb.acquire();
            try testing.expect(tb.indicesArePermutation());
        }
    }
}

test "TripleBuffer: VideoFrame(view型)を値として扱える（deinit不要のPOD/view契約）" {
    var backing = [_]u32{ 0xFF000000, 0xFF00FF00 };
    var tb = TripleBuffer(VideoFrame).init(.{ .pixels = &.{}, .width = 0, .height = 0, .stride = 0, .timestamp_ns = 0, .frame_index = 0 });
    tb.publish(.{ .pixels = &backing, .width = 2, .height = 1, .stride = 2, .timestamp_ns = 123, .frame_index = 1 });
    const got = tb.acquire();
    try testing.expectEqual(@as(u32, 2), got.width);
    try testing.expectEqual(@as(usize, 2), got.pixels.len);
    try testing.expectEqual(@as(u64, 1), got.frame_index);
}

test "TripleBuffer: RT 契約 - publish/acquire は allocator 引数を持たない（型シグネチャで zero-alloc を固定）" {
    // publish/acquire は std.mem.Allocator を一切受け取らない（呼び出しそのものが alloc できない
    // 形）。性能規約の「性能の主張はテストで固定する」に合わせ、シグネチャの引数個数を comptime で
    // 固定しておく（引数が増えて alloc が紛れ込む変更は本テストの型不一致でコンパイルエラーになる）。
    const PublishFn = @TypeOf(TripleBuffer(u32).publish);
    const AcquireFn = @TypeOf(TripleBuffer(u32).acquire);
    try testing.expectEqual(@as(usize, 2), @typeInfo(PublishFn).@"fn".params.len);
    try testing.expectEqual(@as(usize, 1), @typeInfo(AcquireFn).@"fn".params.len);

    // 実際に大量往復させても正しく動作すること（機能面の再確認）。
    var tb = TripleBuffer(u32).init(0);
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        tb.publish(i);
        _ = tb.acquire();
    }
    try testing.expectEqual(@as(u32, 999), tb.acquire().*);
}
