//! Platform abstraction layer (facade)
//!
//! 複数バックエンド対応の Zig interface 層。`builtin.os.tag` で backend を選ぶ。
//!   - macOS → `platform_macos.zig`（C ABI `platform.h` 経由。objc/swift/metal は .o リンクの差のみで Zig 側は共通）
//!   - Linux → `platform_linux.zig`（X11/Wayland。純 Zig で `@cImport(Xlib)` 等を直接呼ぶ。x11/wayland は build_options.platform_backend で選ぶ）
//!   - Windows → `platform_windows.zig`（dispatcher。純 Zig で Win32 API を extern fn で直接呼ぶ。gdi/d3d11 は build_options.platform_backend で選ぶ。TASK-31/35）
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
//!
//! ## 完全 display-less（TASK-32.4 P4）
//!
//! `VP_HARNESS_HEADLESS=1`（+ SCRIPT か LIVE 併用）のとき、`Window` は backend を一切呼ばず
//! harness 所有の CPU framebuffer だけで動く（`platform.init()` も `backend.init()` をスキップする）。
//! `Framebuffer` は facade 独自の struct（`pixels/width/height` + `unlock()`）で、内部に
//! backend fb（native）か headless（harness buffer）かの tagged union を持つ。caller が使うのは
//! `fb.pixels/.width/.height/.unlock()` のみなのでソース互換（apps/synth 等の既存コード無改造）。
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

/// Locked framebuffer view（facade 独自型。TASK-32.4 P4）。
/// caller が使うのは `pixels/width/height/unlock()` のみなので backend 直の型と source 互換。
/// 内部は「native（backend 実体）」か「headless（harness 所有 buffer）」かの tagged union。
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    source: Source,

    const Source = union(enum) {
        native: backend.Framebuffer,
        headless: void,
    };

    pub fn unlock(self: Framebuffer) void {
        switch (self.source) {
            .native => |fb| fb.unlock(),
            .headless => {}, // harness buffer は lock 概念が無い（present まで caller が直接触る）
        }
    }
};

/// Window facade。harness 有効時のみ 4 フックを差し込む。harness 無効時は backend への即パススルー。
/// **headless 時（TASK-32.4 P4）**は `inner` を一切使わず（`undefined` のまま）、harness 所有の
/// CPU framebuffer だけで動く（`backend.init()` 自体が呼ばれないため `inner` は触れない）。
pub const Window = struct {
    inner: backend.Window,
    headless: bool,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        if (harness.isHeadlessActive()) {
            harness.createHeadlessWindow(width, height);
            return .{ .inner = undefined, .headless = true };
        }
        return .{ .inner = try backend.Window.create(width, height, title), .headless = false };
    }

    pub fn destroy(self: Window) void {
        if (self.headless) {
            harness.destroyHeadlessWindow();
            return;
        }
        self.inner.destroy();
    }

    pub fn pollEvents(self: Window) bool {
        if (self.headless) return harness.pollGate(true); // native window closed 相当が無いので常に continue
        const native = self.inner.pollEvents();
        if (!harness.isEnabled()) return native;
        return harness.pollGate(native);
    }

    pub fn nextEvent(self: Window) ?Event {
        if (self.headless) return harness.nextInjectedEvent(); // native pump が無いので注入イベントのみ
        if (!harness.isEnabled()) return self.inner.nextEvent();
        // 注入イベントを優先。尽きたら native を drain して quit のみ通す。
        if (harness.nextInjectedEvent()) |ev| return ev;
        while (self.inner.nextEvent()) |ev| {
            if (harness.filterNativeEvent(ev)) |keep| return keep;
        }
        return null;
    }

    pub fn getEventStats(self: Window) EventStats {
        if (self.headless) return .{ .mouse_move_merge_count = 0, .mouse_scroll_merge_count = 0, .event_drop_count = 0 };
        return self.inner.getEventStats();
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        if (self.headless) {
            const view = harness.headlessLock();
            harness.onLock(view.pixels, view.width, view.height);
            return .{ .pixels = view.pixels, .width = view.width, .height = view.height, .source = .headless };
        }
        const fb = self.inner.lockFramebuffer() orelse {
            if (harness.isEnabled()) harness.onLockMiss();
            return null;
        };
        if (harness.isEnabled()) harness.onLock(fb.pixels, fb.width, fb.height);
        return .{ .pixels = fb.pixels, .width = fb.width, .height = fb.height, .source = .{ .native = fb } };
    }

    pub fn present(self: Window) void {
        if (self.headless) {
            // stats probe 用に EventStats(ゼロ値) を push してから fb 捕捉（onPresent で frame 確定）。
            // headless は isHeadlessActive() 経由でのみ生成されるため実質常に harness 有効だが、
            // native 経路と対称に isEnabled() ガードを揃えておく。
            if (harness.isEnabled()) {
                harness.onStats(self.getEventStats());
                harness.onPresent();
            }
            return;
        }
        if (harness.isEnabled()) {
            // stats probe 用に EventStats を push してから fb 捕捉（onPresent で frame 確定）。
            harness.onStats(self.inner.getEventStats());
            harness.onPresent();
        }
        self.inner.present();
    }
};

pub fn init() Error!void {
    // headless 判定を先に確定させる（env 読取のみ・副作用無し）。headless なら backend.init() 自体を
    // スキップする（display 接続を一切しない。TASK-32.4 P4）。非 headless は従来通り backend→transport の順を保つ。
    harness.parseConfig();
    if (!harness.isHeadlessActive()) {
        try backend.init();
    }
    harness.startTransport();
}

pub fn shutdown() void {
    if (harness.isHeadlessActive()) return; // backend.init() を呼んでいないので shutdown も呼ばない
    backend.shutdown();
}

pub fn getTime() f64 {
    if (harness.isEnabled()) return harness.now();
    return backend.getTime();
}

/// ファイル保存ダイアログ。headless 時は backend が未初期化（native panel / zenity を呼べない）ため
/// 即 `error.DialogFailed` を返す（TASK-32.4 P4）。
pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    if (harness.isHeadlessActive()) return error.DialogFailed;
    return backend.saveFileDialog(gpa, io, opts);
}

/// ファイルを開くダイアログ。headless 時は即 `error.DialogFailed`（`saveFileDialog` と同じ理由）。
pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    if (harness.isHeadlessActive()) return error.DialogFailed;
    return backend.openFileDialog(gpa, io, opts);
}

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

/// フレーム毎の main loop ウェイト（TASK-32.4 P4）。harness 有効時（headless に限らず replay/live とも）は
/// **no-op**（フレーム進行は `pollGate` が gate し、時刻は仮想クロックなので実時間 sleep は純粋な待ち損＝
/// replay 速度の律速要因）。harness 無効時は `sleep()` と同じ。main/examples の frame-wait 呼び出しは
/// これに置き換える（`sleep()` 自体はフレームウェイト以外の用途向けに残す）。
pub fn frameDelay(nanoseconds: u64) void {
    if (harness.isEnabled()) return;
    sleep(nanoseconds);
}
