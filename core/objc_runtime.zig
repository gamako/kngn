//! Objective-C ランタイム最小 FFI ヘルパー（TASK-49.2）。
//!
//! AVFoundation（camera）や `AVCaptureDevice` の権限確認（mic 側も同じクラスを使う。設計文書
//! `docs/plans/capture-foundation-plan.md` 6章）は Objective-C オンリーの API（C API が無い）ため、
//! `@cImport`/Swift を使わず libobjc の C ABI（`objc_msgSend`/`objc_getClass`/`sel_registerName`/
//! 動的クラス生成/手書き Objective-C block）を extern fn で直接叩く。既存 backend の
//! 「AudioToolbox を extern fn で直接叩く」「Windows D3D11 の COM vtable 手書き」と同じ
//! 「他言語ランタイムを C ABI 経由で直呼びする」方針の横展開。
//!
//! **aarch64-darwin のみ対応**（本プロジェクトの macOS 対応 system は flake.nix により
//! aarch64-darwin 限定。arm64 の統一呼出規約では `objc_msgSend` が全戻り値型で共通に使え、
//! x86_64 で必要な `objc_msgSend_stret`/`objc_msgSend_fpret` の分岐は不要なため実装しない）。
//!
//! `camera_macos.zig`（camera module）と `audio_macos.zig`（audio module。マイク権限確認）の
//! 両方から使われる。状態を持たない純粋関数群のみで型を跨いだ共有が無いため、
//! `capture_types.zig` のような**型同一性**の理由での named module 化は不要（8章参照）だったが、
//! **同一ファイルが2つの異なる module に属することはできない**という Zig の別の制約により、
//! 結局 named module 化が必要になった（TASK-49.6: camera モジュールと audio モジュールを
//! 同一 exe に同時 link する初のケース＝mic+camera 両方を使うデモで
//! 「file exists in modules 'camera' and 'audio'」build エラーとして発覚。camera_macos.zig/
//! audio_macos.zig がそれぞれ相対 `@import("objc_runtime.zig")` していたため、両 module が
//! 同一 exe に link されると同じ物理ファイルが2 module に属する矛盾になっていた）。
//! `core/build.zig` の `SharedModules` が named module `objc_runtime` として1個だけ作り、
//! `camera`/`audio` 両方に `link()` する。
//!
//! ホットパス宣言: 初期化時のみ（`open()`/`requestPermission()`/`close()` 等イベント時に
//! 数回呼ばれるのみ。フレーム毎(全画素)/RT(毎サンプル)では一切呼ばれない）。

const std = @import("std");

pub const Id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;

pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
pub extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn class_addMethod(cls: Class, sel: SEL, imp: *const anyopaque, types: [*:0]const u8) u8; // BOOL
pub extern "c" fn class_addProtocol(cls: Class, proto: ?*anyopaque) u8; // BOOL
pub extern "c" fn objc_msgSend() void; // 実シグネチャは呼び出し側で @ptrCast する（下記 msgSend 参照）

/// クラスを名前で取得する（`objc_getClass` のラッパー。null なら未ロード＝リンクした framework が
/// まだ dyld に解決されていない/名前typo）。
pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

/// セレクタを名前で取得する（`sel_registerName` のラッパー）。
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// `objc_msgSend` を呼び出し側の型で呼ぶ。Objective-C のメッセージ送信は可変長引数的だが、
/// arm64 の統一 ABI では通常の C 呼出規約と一致するため、comptime に呼び出しごとの関数型を
/// `@Fn`（Zig 0.16 の型 reify builtin。旧 `@Type(.{ .@"fn" = ... })` はこのバージョンには
/// 存在せず種類別 builtin に分割されている）で組み立てて `@ptrCast` する
/// （`zig-objc` 等の Zig ObjC binding と同型のテクニック）。
pub fn msgSend(comptime Ret: type, obj: Id, sel_val: SEL, args: anytype) Ret {
    const ArgsType = @TypeOf(args);
    const FnType = comptime blk: {
        const fields = std.meta.fields(ArgsType);
        var param_types: [fields.len + 2]type = undefined;
        param_types[0] = Id;
        param_types[1] = SEL;
        for (fields, 0..) |f, i| param_types[i + 2] = f.type;
        const fixed_types = param_types;

        var param_attrs: [fields.len + 2]std.builtin.Type.Fn.Param.Attributes = undefined;
        for (&param_attrs) |*a| a.* = .{};
        const fixed_attrs = param_attrs;

        break :blk @Fn(&fixed_types, &fixed_attrs, Ret, .{ .@"callconv" = .c });
    };
    const func: *const FnType = @ptrCast(&objc_msgSend);
    return @call(.auto, func, .{ obj, sel_val } ++ args);
}

// ============================================================================
// 手書き Objective-C block（TASK-49.2: AVCaptureDevice.requestAccessForMediaType:completionHandler:
// の非同期 completion handler / dispatch_sync の drain block に使う。設計文書 §「未確定」の
// 「非同期→同期ブロッキング変換」を手書き stack block + busy-wait で実装する）。
// ============================================================================

/// libclosure（blocks runtime。libSystem 内蔵）が公開するスタックブロック用 isa。
/// 参照するだけで呼び出さない（アドレスを isa に埋め込む）。
extern "c" var _NSConcreteStackBlock: anyopaque;

pub const BlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize,
};

/// **BLOCK_HAS_COPY_DISPOSE を持たない**手書き stack block。捕捉するのは POD な `ctx` ポインタ
/// 1個のみ（retain/release が要る Objective-C オブジェクトを捕捉しない）ため、ランタイムが
/// `Block_copy` する際も単純なバイトコピーで済み安全に使える。`invoke` は
/// `fn(*const StackBlock, ...args) callconv(.c) Ret` の形（第1引数は block 自身。標準 blocks ABI）
/// で外部から呼ばれる。
pub const StackBlock = extern struct {
    isa: ?*anyopaque,
    flags: i32 = 0,
    reserved: i32 = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
    ctx: ?*anyopaque,
};

var stack_block_descriptor = BlockDescriptor{ .size = @sizeOf(StackBlock) };

/// `invoke`（呼び出し側の実シグネチャへ `@ptrCast` 済みの関数ポインタ）と `ctx`（POD ペイロード。
/// invoke 内で `block.ctx` から取り出す）から stack block を組み立てる。返した値は呼び出しが
/// 完了するまで（同期待ちが終わるまで）スタック上で生存させること（caller 責務。エスケープさせない）。
pub fn makeStackBlock(invoke: *const anyopaque, ctx: ?*anyopaque) StackBlock {
    return .{
        .isa = &_NSConcreteStackBlock,
        .invoke = invoke,
        .descriptor = &stack_block_descriptor,
        .ctx = ctx,
    };
}

// ============================================================================
// AVCaptureDevice 権限確認ヘルパー（mic/camera 共有。設計文書
// `docs/plans/capture-foundation-plan.md` 6章: 両者とも
// `AVCaptureDevice.authorizationStatusForMediaType:`/`requestAccessForMediaType:completionHandler:`
// を使う。`media_type`（`AVMediaTypeVideo`/`AVMediaTypeAudio`）は呼び出し側=各 backend ファイルが
// 渡す。ここに置くのは block 構築という手のかかる共通ロジックを camera/audio 間で複製しないため）。
// ============================================================================

/// `[AVCaptureDevice authorizationStatusForMediaType:media_type]` を呼ぶ（TCC ダイアログを
/// 出さない単なるクエリ）。戻り値は `AVAuthorizationStatus`（NSInteger:
/// notDetermined=0/restricted=1/denied=2/authorized=3）をそのまま返す。
pub fn avAuthorizationStatus(media_type: Id) i64 {
    const cls = getClass("AVCaptureDevice");
    return msgSend(i64, cls, sel("authorizationStatusForMediaType:"), .{media_type});
}

const RequestAccessCtx = struct {
    done: std.atomic.Value(bool) = .init(false),
    granted: bool = false,
};

fn requestAccessInvoke(block: *const StackBlock, granted: bool) callconv(.c) void {
    const ctx: *RequestAccessCtx = @ptrCast(@alignCast(block.ctx.?));
    ctx.granted = granted;
    ctx.done.store(true, .release);
}

fn sleepMsForRequestAccess(ms: u64) void {
    var req = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&req, null);
}

/// `[AVCaptureDevice requestAccessForMediaType:media_type completionHandler:^(BOOL granted){...}]`
/// を呼び、completion handler が発火するまでブロックする（非同期→同期変換）。busy-wait
/// （1ms sleep のポーリング）で実装する（イベント時のみ・1回限りの待ち合わせなので実用上問題ない。
/// 設計文書の「semaphore か dispatch queue 待ち合わせか」という未確定事項に対する結論）。
/// **未決定(.notDetermined)から遷移させる呼び出しであり、初回は実際に TCC ダイアログを試みる**
/// （自動テストからは呼ばないこと。手動検証レンジ。backlog task-49.2 参照）。
pub fn avRequestAccessBlocking(media_type: Id) bool {
    var ctx = RequestAccessCtx{};
    const block = makeStackBlock(@ptrCast(&requestAccessInvoke), &ctx);
    const cls = getClass("AVCaptureDevice");
    msgSend(void, cls, sel("requestAccessForMediaType:completionHandler:"), .{ media_type, &block });
    while (!ctx.done.load(.acquire)) {
        sleepMsForRequestAccess(1);
    }
    return ctx.granted;
}

// ============================================================================
// tests（display/実デバイス不要。NSObject/NSString 等 libobjc + Foundation の基本メッセージ送信の
// 疎通確認のみ。TCC・実デバイスに一切触れない）
// ============================================================================
const testing = std.testing;

test "msgSend: [NSObject new] は非 nil を返し isKindOfClass: が真になる" {
    const cls = getClass("NSObject");
    try testing.expect(cls != null);
    const obj = msgSend(Id, cls, sel("new"), .{});
    try testing.expect(obj != null);
    defer _ = msgSend(void, obj, sel("release"), .{});

    const is_kind = msgSend(bool, obj, sel("isKindOfClass:"), .{cls});
    try testing.expect(is_kind);
}

test "msgSend: NSString length/UTF8String が引数付きメッセージで正しく動く" {
    const cls = getClass("NSString");
    try testing.expect(cls != null);
    const str = msgSend(Id, cls, sel("stringWithUTF8String:"), .{@as([*:0]const u8, "hello")});
    try testing.expect(str != null);
    const len = msgSend(usize, str, sel("length"), .{});
    try testing.expectEqual(@as(usize, 5), len);
    const c_str = msgSend([*:0]const u8, str, sel("UTF8String"), .{});
    try testing.expectEqualStrings("hello", std.mem.span(c_str));
}

test "makeStackBlock: invoke がリンクした isa/ctx を伴って正しく呼ばれる（ObjC非依存の純粋な呼び出しテスト）" {
    const Ctx = struct { value: i32 = 0 };
    const Invoker = struct {
        fn call(block: *const StackBlock, add: i32) callconv(.c) void {
            const ctx: *Ctx = @ptrCast(@alignCast(block.ctx.?));
            ctx.value += add;
        }
    };
    var ctx = Ctx{};
    const block = makeStackBlock(@ptrCast(&Invoker.call), &ctx);
    try testing.expect(block.isa != null);
    try testing.expectEqual(@sizeOf(StackBlock), block.descriptor.size);

    const Fn = *const fn (*const StackBlock, i32) callconv(.c) void;
    const f: Fn = @ptrCast(@alignCast(block.invoke));
    f(&block, 7);
    try testing.expectEqual(@as(i32, 7), ctx.value);
}
