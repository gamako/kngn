//! Platform abstraction layer (facade)
//!
//! 複数バックエンド対応の Zig interface 層。`builtin.os.tag` で backend を選ぶ。
//!   - macOS → `platform_macos.zig`（C ABI `platform.h` 経由。objc/swift/metal は .o リンクの差のみで Zig 側は共通）
//!   - Linux → `platform_linux.zig`（X11/Wayland。純 Zig で `@cImport(Xlib)` 等を直接呼ぶ。x11/wayland は build_options.platform_backend で選ぶ）
//!   - Windows → `platform_windows.zig`（Win32 + GDI。純 Zig で Win32 API を extern fn で直接呼ぶ。TASK-31）
//!
//! 公開型（KeyCode / Event 等）は `platform_types.zig` を単一ソースとして re-export し、
//! `Window`/`Framebuffer` と関数群だけを各 backend から re-export する。
//! （Zig 0.16 で `pub usingnamespace` が削除されたため、明示的に列挙する。）
//!
//! ## ヘッドレス検証 harness（TASK-32.1）
//!
//! `Window` を薄い wrapper 化し、唯一の入力/出力チョークポイント4箇所を `harness.zig` に interpose する:
//!   - `pollEvents` = フレーム進行の同期点（replay の step gate）
//!   - `nextEvent`  = 注入イベント（+ native は quit のみ通す）
//!   - `present`    = `fb` probe 捕捉（owned copy）
//!   - `getTime`    = 仮想クロック
//! env `VP_HARNESS_SCRIPT` 未設定なら全フックは即パススルー（既存挙動と完全一致）。
//! `Framebuffer` は backend のものをそのまま re-export（caller の fb.pixels/.unlock() 互換を保つ）。
//!
//! ## canonical pixel format（全 OS 共通・TASK-28.6）
//!
//! framebuffer のピクセルは **canonical BGRA**: u32 `0xAARRGGBB`（リトルエンディアンの
//! メモリ上は `[B, G, R, A]`）。pack = `(a<<24)|(r<<16)|(g<<8)|b`。web 16進 `0xRRGGBB` が
//! 低 24bit にそのまま一致する。Windows(GDI/DXGI)・X11 標準 visual・macOS(CGImage/Metal) が
//! 共通して BGRA を native に扱えるため、中間変換層も実行時分岐も持たず全 OS で直書きできる。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
// harness は共有 module（src/audio.zig facade も同一インスタンスを import し module-level state を共有する）。
// このため source-relative `@import("harness.zig")` ではなく名前付き module import を使う (TASK-32.2)。
const harness = @import("harness");

const backend = switch (builtin.os.tag) {
    .macos => @import("platform_macos.zig"),
    .linux => @import("platform_linux.zig"),
    .windows => @import("platform_windows.zig"),
    else => @compileError("video-proto: unsupported OS for platform backend: " ++ @tagName(builtin.os.tag)),
};

// 型は platform_types を単一ソースに re-export（backend 間で乖離させない）
pub const Error = types.Error;
pub const KeyCode = types.KeyCode;
pub const ModifierFlags = types.ModifierFlags;
pub const KeyEvent = types.KeyEvent;
pub const MouseButton = types.MouseButton;
pub const MouseButtons = types.MouseButtons;
pub const MouseEvent = types.MouseEvent;
pub const ScrollEvent = types.ScrollEvent;
pub const Event = types.Event;
pub const EventStats = types.EventStats;
pub const DialogError = types.DialogError;
pub const SaveDialogOptions = types.SaveDialogOptions;
pub const OpenDialogOptions = types.OpenDialogOptions;

// Framebuffer は backend のものをそのまま re-export（wrap しない）。
pub const Framebuffer = backend.Framebuffer;

/// Window facade。backend.Window を内包し、harness 有効時のみ 4 フックを差し込む。
/// harness 無効時は全メソッドが backend への即パススルー。
pub const Window = struct {
    inner: backend.Window,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        return .{ .inner = try backend.Window.create(width, height, title) };
    }

    pub fn destroy(self: Window) void {
        self.inner.destroy();
    }

    pub fn pollEvents(self: Window) bool {
        const native = self.inner.pollEvents();
        if (!harness.isEnabled()) return native;
        return harness.pollGate(native);
    }

    pub fn nextEvent(self: Window) ?Event {
        if (!harness.isEnabled()) return self.inner.nextEvent();
        // 注入イベントを優先。尽きたら native を drain して quit のみ通す。
        if (harness.nextInjectedEvent()) |ev| return ev;
        while (self.inner.nextEvent()) |ev| {
            if (harness.filterNativeEvent(ev)) |keep| return keep;
        }
        return null;
    }

    pub fn getEventStats(self: Window) EventStats {
        return self.inner.getEventStats();
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        const fb = self.inner.lockFramebuffer() orelse {
            if (harness.isEnabled()) harness.onLockMiss();
            return null;
        };
        if (harness.isEnabled()) harness.onLock(fb.pixels, fb.width, fb.height);
        return fb;
    }

    pub fn present(self: Window) void {
        if (harness.isEnabled()) {
            // stats probe 用に EventStats を push してから fb 捕捉（onPresent で frame 確定）。
            harness.onStats(self.inner.getEventStats());
            harness.onPresent();
        }
        self.inner.present();
    }
};

pub fn init() Error!void {
    try backend.init();
    harness.init();
}

pub fn shutdown() void {
    backend.shutdown();
}

pub fn getTime() f64 {
    if (harness.isEnabled()) return harness.now();
    return backend.getTime();
}

pub const saveFileDialog = backend.saveFileDialog;
pub const openFileDialog = backend.openFileDialog;

// ============================================================================
// custom probe（ヘッドレス検証 harness・TASK-32.3）
//
// app が `platform.registerProbe(.{ .name, .ctx, .snapshot, .digest })` で probe を opt-in 登録する。
// platform module は共有 harness module を既に import 済みなので re-export だけで露出でき、build.zig 変更は不要。
// harness 無効時（env 未設定）は registerProbe が no-op。framework は probe の中身を解釈しない。
// ============================================================================
pub const Probe = harness.Probe;
pub const registerProbe = harness.registerProbe;

// ============================================================================
// sleep（OS 非依存のフレームウェイト）
//
// zig 0.16 は std.time.sleep を廃し sleep が std.Io 経由になったため、main/examples が共通で使える
// 単純な遅延を facade に置く。backend を増やさず comptime OS 分岐で済む（POSIX=nanosleep, Windows=Sleep）。
// unselected 分岐は comptime-known 条件のため解析されない（winapi extern が POSIX を壊さない）。
// ============================================================================
const win_sleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
} else struct {};

/// 指定ナノ秒だけ最低限スリープする（精度は OS 依存）。
pub fn sleep(nanoseconds: u64) void {
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
