//! A minimal FFI helper for the Objective-C runtime.
//!
//! AVFoundation (the camera) and `AVCaptureDevice`'s permission check (the microphone side uses the same class;
//! see `docs/capture.md`) are Objective-C-only APIs with no C API, so rather than
//! `@cImport` or Swift this drives libobjc's C ABI (`objc_msgSend`, `objc_getClass`, `sel_registerName`,
//! dynamic class creation and hand-written Objective-C blocks) directly through extern fn. It extends the
//! approach the existing backends already take — driving AudioToolbox directly through extern fn, and
//! hand-writing the COM vtable for Windows D3D11 — of calling another language's runtime through the C ABI.
//!
//! **Only aarch64-darwin is supported** (this project's macOS system is limited to
//! aarch64-darwin by flake.nix. Under arm64's uniform calling convention `objc_msgSend` works for every
//! return type, so the `objc_msgSend_stret` and `objc_msgSend_fpret` branches that x86_64 needs are not implemented).
//!
//! It is used by both `camera_macos.zig` (the camera module) and `audio_macos.zig` (the audio module, for the
//! microphone permission check). Being only stateless pure functions with nothing shared across types, it does
//! not need to be a named module for the **type identity** reason `capture_types.zig` does.
//! A different Zig constraint forces it anyway: **one file cannot belong to two different modules**.
//! Linking the camera module and the audio module into one executable (a demo using both a microphone and a
//! camera) surfaces this as the build error "file exists in modules 'camera' and 'audio'", because
//! camera_macos.zig and audio_macos.zig each did a relative `@import("objc_runtime.zig")`, so linking both
//! modules into one executable made the same physical file belong to two modules, which Zig
//! rejects outright.
//! `SharedModules` in `core/build.zig` therefore creates exactly one named module `objc_runtime` and
//! `link()`s it into both `camera` and `audio`.
//!
//! Hot path declaration: initialisation time only (called a handful of times at event time, in `open()`,
//! `requestPermission()`, `close()` and the like. Never per frame (over every pixel) or real-time (per sample)).

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
pub extern "c" fn objc_msgSend() void; // the caller @ptrCasts to the real signature (see msgSend below)

/// Gets a class by name (a wrapper over `objc_getClass`; null means it is not loaded, so a linked framework
/// has not been resolved by dyld yet, or the name is a typo).
pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

/// Gets a selector by name (a wrapper over `sel_registerName`).
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Calls `objc_msgSend` with the caller's own types. Sending an Objective-C message is variadic in spirit, but
/// under arm64's uniform ABI it matches the ordinary C calling convention, so the function type for each call is
/// assembled at comptime with `@Fn` (Zig 0.16's type reification builtin; the older `@Type(.{ .@"fn" = ... })`
/// does not exist in this version, having been split into per-kind builtins) and then `@ptrCast`
/// (the same technique as Zig ObjC bindings such as `zig-objc`).
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
// A hand-written Objective-C block, used for the asynchronous completion handler of
// AVCaptureDevice.requestAccessForMediaType:completionHandler: and for dispatch_sync's drain block.
// It implements the asynchronous-to-synchronous-blocking conversion with a hand-written stack block plus a busy-wait.
// ============================================================================

/// The isa for a stack block, published by libclosure (the blocks runtime, built into libSystem).
/// It is only referenced, never called (its address is embedded in isa).
extern "c" var _NSConcreteStackBlock: anyopaque;

pub const BlockDescriptor = extern struct {
    reserved: usize = 0,
    size: usize,
};

/// A hand-written stack block that **has no BLOCK_HAS_COPY_DISPOSE**. It captures only one POD `ctx`
/// pointer (never an Objective-C object needing retain and release), so even when the runtime
/// `Block_copy`s it a plain byte copy suffices and it stays safe. `invoke` is called from outside in the
/// shape `fn(*const StackBlock, ...args) callconv(.c) Ret`
/// (the first argument being the block itself, per the standard blocks ABI).
pub const StackBlock = extern struct {
    isa: ?*anyopaque,
    flags: i32 = 0,
    reserved: i32 = 0,
    invoke: *const anyopaque,
    descriptor: *const BlockDescriptor,
    ctx: ?*anyopaque,
};

var stack_block_descriptor = BlockDescriptor{ .size = @sizeOf(StackBlock) };

/// Assembles a stack block from `invoke` (a function pointer already `@ptrCast` to the caller's real signature)
/// and `ctx` (the POD payload, retrieved from `block.ctx` inside invoke). The value returned must be kept alive
/// on the stack until the call completes (until the synchronous wait ends); that is the caller's duty, and it must not escape.
pub fn makeStackBlock(invoke: *const anyopaque, ctx: ?*anyopaque) StackBlock {
    return .{
        .isa = &_NSConcreteStackBlock,
        .invoke = invoke,
        .descriptor = &stack_block_descriptor,
        .ctx = ctx,
    };
}

// ============================================================================
// The AVCaptureDevice permission helper, shared by the microphone and camera (see `docs/capture.md`: both use
// the same class.
// `AVCaptureDevice.authorizationStatusForMediaType:`/`requestAccessForMediaType:completionHandler:`
// `media_type` (`AVMediaTypeVideo` or `AVMediaTypeAudio`) is passed in by the caller, each backend file.
// It lives here so that the fiddly shared logic of building the block is not duplicated between camera and audio).
// ============================================================================

/// Calls `[AVCaptureDevice authorizationStatusForMediaType:media_type]` (a plain query that does not raise
/// the TCC dialogue). It returns `AVAuthorizationStatus` (an NSInteger:
/// notDetermined=0, restricted=1, denied=2, authorized=3) as it is.
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
/// and blocks until the completion handler fires (the asynchronous-to-synchronous conversion). It is implemented
/// with a busy-wait (polling with a 1ms sleep), which is fine in practice, being a one-off wait at event time only.
/// That is the resolution of the open question of whether to use a semaphore or to wait on a dispatch queue.
/// **This call transitions away from notDetermined, so the first time it really does attempt the TCC dialogue.**
/// Do not call it from an automated test; it is for manual verification.
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
// tests (no display or real device needed. They only check that basic message sending through libobjc and
// Foundation works, with NSObject, NSString and the like, and never touch TCC or a real device)
// ============================================================================
const testing = std.testing;

test "msgSend: [NSObject new] returns non-nil and isKindOfClass: holds" {
    const cls = getClass("NSObject");
    try testing.expect(cls != null);
    const obj = msgSend(Id, cls, sel("new"), .{});
    try testing.expect(obj != null);
    defer _ = msgSend(void, obj, sel("release"), .{});

    const is_kind = msgSend(bool, obj, sel("isKindOfClass:"), .{cls});
    try testing.expect(is_kind);
}

test "msgSend: NSString length and UTF8String work correctly through a message with arguments" {
    const cls = getClass("NSString");
    try testing.expect(cls != null);
    const str = msgSend(Id, cls, sel("stringWithUTF8String:"), .{@as([*:0]const u8, "hello")});
    try testing.expect(str != null);
    const len = msgSend(usize, str, sel("length"), .{});
    try testing.expectEqual(@as(usize, 5), len);
    const c_str = msgSend([*:0]const u8, str, sel("UTF8String"), .{});
    try testing.expectEqualStrings("hello", std.mem.span(c_str));
}

test "makeStackBlock: invoke is called correctly with the linked isa and ctx (a pure call test, independent of ObjC)" {
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
