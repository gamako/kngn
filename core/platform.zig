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
const command_types = @import("command_types");
// harness は共有 module（src/audio.zig facade も同一インスタンスを import し module-level state を共有する）。
// このため source-relative `@import("harness.zig")` ではなく名前付き module import を使う (TASK-32.2)。
const harness = @import("harness");
// copilot（通常 UX と共存する assist transport。TASK-62.5.2）。harness module 内の namespace
// 再エクスポート経由で参照する（意味的依存は copilot→harness の一方向）。
const copilot = harness.copilot;
const netsync = harness.netsync;
// ゲームパッド実 backend（GameController framework）の opt-in フラグ（TASK-80.2 opt-in 化。audio の
// `link_audio` と対称）。build.zig の `createPlatformModule`/`buildStandalone` が常にこの named import を
// 付与するため（外部公開 module も含む）、全 caller で安全に参照できる。
const build_options = @import("build_options");

const backend = if (builtin.cpu.arch.isWasm())
    @import("platform_wasm.zig")
else switch (builtin.os.tag) {
    .macos => @import("platform_macos.zig"),
    .linux => @import("platform_linux.zig"),
    .windows => @import("platform_windows.zig"),
    else => @compileError("video-proto: unsupported OS for platform backend: " ++ @tagName(builtin.os.tag)),
};

fn nativePumpPoll(ctx: *anyopaque) bool {
    const inner: *backend.Window = @ptrCast(@alignCast(ctx));
    return inner.pollEvents();
}

// ============================================================================
// ライブリサイズ redraw コールバック（TASK-23.1）
// ============================================================================
//
// OS のモーダル/ネストした event-tracking ループ（枠ドラッグ中）から app へ
// 「今 1 フレーム描いてほしい」とだけ通知する opt-in 機構。
//
// 契約:
// - callback は**イベントポンプ（pollEvents 内の sendEvent / DispatchMessageW）実行中**に呼ばれる。
// - callback 内で `pollEvents` を呼んではならない（ネイティブポンプへの再入）。
// - `nextEvent` はキューを読むだけ（ポンプしない）なので呼んでよい。
// - モーダルダイアログ（file dialog）を callback から開いてはならない。
// - lockFramebuffer 保持中に pollEvents を呼ぶ設計のアプリは登録不可。
// - 単一プロセス・単一ウィンドウ前提の module-level 状態（harness / registerProbe と同じ設計）。
// - harness 有効時（VP_HARNESS_*）は登録自体をしない（frame_index / 仮想クロック / replay の
//   bit 決定論を壊さないため。registerProbe の「harness 無効時 no-op」と対称）。

/// OS モーダルループ中に backend が 1 フレームの描画を app へ要求するコールバック型。
pub const RedrawFn = *const fn (ctx: *anyopaque) void;

var redraw_guard: struct {
    ctx: *anyopaque = undefined,
    cb: ?RedrawFn = null,
    in_callback: bool = false,
} = .{};

fn redrawWrapper(ctx: *anyopaque) void {
    _ = ctx;
    if (redraw_guard.in_callback) return;
    const cb = redraw_guard.cb orelse return;
    redraw_guard.in_callback = true;
    defer redraw_guard.in_callback = false;
    cb(redraw_guard.ctx);
}

// 型は platform_types を単一ソースに re-export（backend 間で乖離させない）
pub const Error = types.Error;
pub const KeyCode = types.KeyCode;
pub const ModifierFlags = types.ModifierFlags;
pub const KeyEvent = types.KeyEvent;
pub const CharEvent = types.CharEvent;
pub const CompositionPhase = types.CompositionPhase;
pub const CompositionEvent = types.CompositionEvent;
pub const CompositionSnapshot = types.CompositionSnapshot;
pub const MouseButton = types.MouseButton;
pub const MouseButtons = types.MouseButtons;
pub const MouseEvent = types.MouseEvent;
pub const ScrollEvent = types.ScrollEvent;
pub const Event = types.Event;
pub const EventStats = types.EventStats;
pub const FileDropPath = types.FileDropPath;
pub const FileDropEvent = types.FileDropEvent;
pub const FILE_DROP_PATH_BYTES = types.FILE_DROP_PATH_BYTES;
pub const FILE_DROP_MAX_PATHS = types.FILE_DROP_MAX_PATHS;
pub const makeFileDropEventFromPath = types.makeFileDropEventFromPath;
pub const CommandId = command_types.CommandId;
pub const Command = command_types.Command;
pub const CommandKind = command_types.CommandKind;
pub const ExecutionPolicy = command_types.ExecutionPolicy;
pub const Shortcut = command_types.Shortcut;
pub const DialogError = types.DialogError;
pub const SaveDialogOptions = types.SaveDialogOptions;
pub const OpenDialogOptions = types.OpenDialogOptions;
pub const CursorShape = types.CursorShape;
pub const WindowOptions = types.WindowOptions; // TASK-104 / TASK-117
pub const WindowPosition = types.WindowPosition; // TASK-117
pub const WindowSize = types.WindowSize; // TASK-117
pub const WindowGeometry = types.WindowGeometry; // TASK-117
pub const MAX_GAMEPADS = types.MAX_GAMEPADS;
pub const GamepadButton = types.GamepadButton;
pub const GamepadButtons = types.GamepadButtons;
pub const Stick = types.Stick;
pub const GamepadState = types.GamepadState;
pub const GamepadInfo = types.GamepadInfo;
pub const GamepadDisconnect = types.GamepadDisconnect;

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
    /// headless getGeometry 用に作成時サイズを保持する（TASK-117。native は backend 取得）。
    create_w: u32 = 0,
    create_h: u32 = 0,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        if (harness.isHeadlessActive()) {
            harness.createHeadlessWindow(width, height) catch return error.WindowCreationFailed;
            return .{ .inner = undefined, .headless = true, .create_w = width, .create_h = height };
        }
        return .{ .inner = try backend.Window.create(width, height, title), .headless = false, .create_w = width, .create_h = height };
    }

    /// 本物のフルスクリーンウィンドウを作成する（agent-face 向け。TASK-100。video-proto に
    /// OS レベルのフルスクリーン切替 API が無かったため追加）。`backend.Window` が
    /// `createFullscreen` を実装していれば（Linux x11/wayland）それを使い、無ければ
    /// 固定サイズの通常ウィンドウへフォールバックする（macOS/Windows backend は無改造）。
    /// ホットパス宣言: 初期化時のみ（ウィンドウ生成 1 回）。
    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        if (harness.isHeadlessActive()) {
            harness.createHeadlessWindow(1920, 1080) catch return error.WindowCreationFailed;
            return .{ .inner = undefined, .headless = true, .create_w = 1920, .create_h = 1080 };
        }
        if (@hasDecl(backend.Window, "createFullscreen")) {
            return .{ .inner = try backend.Window.createFullscreen(title), .headless = false, .create_w = 1920, .create_h = 1080 };
        }
        return .{ .inner = try backend.Window.create(1920, 1080, title), .headless = false, .create_w = 1920, .create_h = 1080 };
    }

    /// 透過 / borderless / 初期位置・サイズ オプション付きでウィンドウを作成する（TASK-104 / TASK-117）。
    /// `.{}` は従来 create と同一挙動（後方互換）。`opts.size` 指定時だけ w/h を上書きする。
    /// backend が `createWithOptions` を実装していればそれを使い、無ければ透過/borderless 要求時に
    /// `error.Unsupported`、無指定なら通常 create へフォールバックする。
    /// headless（VP_HARNESS_HEADLESS）は options を受理し CPU framebuffer だけで動く
    /// （表示は無いが fb の alpha を digest 検証できる。位置は常に null）。
    /// ホットパス宣言: 初期化時のみ（ウィンドウ生成 1 回）。
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: WindowOptions) Error!Window {
        const w = if (opts.size) |s| s.width else width;
        const h = if (opts.size) |s| s.height else height;
        if (harness.isHeadlessActive()) {
            harness.createHeadlessWindow(w, h) catch return error.WindowCreationFailed;
            return .{ .inner = undefined, .headless = true, .create_w = w, .create_h = h };
        }
        if (@hasDecl(backend.Window, "createWithOptions")) {
            return .{ .inner = try backend.Window.createWithOptions(w, h, title, opts), .headless = false, .create_w = w, .create_h = h };
        }
        if (opts.transparent or opts.borderless) return error.Unsupported;
        return .{ .inner = try backend.Window.create(w, h, title), .headless = false, .create_w = w, .create_h = h };
    }

    /// 現在のウィンドウ geometry を返す（TASK-117）。エラーを返さず安全な既定値を返す。
    /// headless は作成時サイズ + position=null。backend 未実装は size=0 + position=null。
    /// ホットパス宣言: ウィンドウ生成時 / 終了時 shutdown / harness digest 観測時のみ。
    pub fn getGeometry(self: Window) WindowGeometry {
        if (self.headless) {
            return .{
                .position = null,
                .size = .{ .width = self.create_w, .height = self.create_h },
            };
        }
        if (comptime @hasDecl(backend, "getGeometry")) {
            return backend.getGeometry(self.inner);
        }
        return .{ .position = null, .size = .{ .width = 0, .height = 0 } };
    }

    pub fn destroy(self: Window) void {
        // callback clear は public setRedrawCallback に null を通さず、facade/backend の
        // private clear 経路で行う（TASK-23.1 実装メモ）。destroy 後の遅延 setFrameSize 防御。
        redraw_guard = .{};
        if (self.headless) {
            harness.destroyHeadlessWindow();
            return;
        }
        self.inner.clearRedrawCallback();
        self.inner.destroy();
    }

    /// OS の close/quit 要求を consumer がキャンセルし、window を継続する。
    /// ホットパス宣言: quit/close イベント時のみ。headless は no-op。
    pub fn cancelQuit(self: Window) void {
        if (self.headless) return;
        if (@hasDecl(backend.Window, "cancelQuit")) self.inner.cancelQuit();
    }

    pub fn pollEvents(self: Window) bool {
        // netsync.pump は headless の pollGate 早期 return より前（全経路・毎フレーム。TASK-62.3.2）。
        // queue 空なら即 return。env 未設定時も started ガードでパススルー。
        netsync.pump();
        if (self.headless) return harness.pollGate(true); // native window closed 相当が無いので常に continue
        var inner = self.inner;
        const native = inner.pollEvents();
        if (!harness.isEnabled()) {
            // 通常 UX の毎フレーム末尾で copilot transport を進める（disabled 時は即 return の no-op。
            // harness 有効時は排他により copilot は必ず disabled なので、このパスに置くだけで足りる）。
            copilot.pump();
            return native;
        }
        const pump = harness.NativePump{
            .ptr = @ptrCast(&inner),
            .pollFn = nativePumpPoll,
        };
        return harness.pollGateWithPump(native, pump);
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

    /// カーソル形状を設定する（システムカーソル。TASK-75.1）。
    /// ホットパス宣言: ツール切替等の**イベント時のみ**呼ぶ想定（フレーム毎/RT ではない。
    /// 性能規約の対象外）。headless 時（表示先が無い＝VP_HARNESS_HEADLESS）は no-op（AC#3）。
    /// probe が観測する値ではない（副作用が表示にしか出ない）ため harness 側のフック追加は不要。
    pub fn setCursor(self: Window, shape: CursorShape) void {
        if (self.headless) return;
        self.inner.setCursor(shape);
    }

    /// 表示中の OS ウィンドウタイトルを更新する。状態遷移時のみ呼ぶ。
    /// headless と未対応 backend は no-op とし、framebuffer を変更しない。
    pub fn setTitle(self: Window, title: [:0]const u8) void {
        if (self.headless) return;
        if (@hasDecl(backend.Window, "setTitle")) self.inner.setTitle(title);
    }

    /// 直近のポインタ押下から OS の対話的ウィンドウ移動を開始する（TASK-104）。
    /// アプリは掴む領域で mouse_down を受けたら呼ぶ。backend 未対応・headless は no-op。
    /// ホットパス宣言: mouse_down 起点のイベント時のみ。
    pub fn beginDrag(self: Window) void {
        if (self.headless) return;
        if (@hasDecl(backend.Window, "beginDrag")) self.inner.beginDrag();
    }

    /// 常に最前面（always-on-top）を設定する（TASK-104）。backend 未対応・headless は no-op。イベント時のみ。
    pub fn setAlwaysOnTop(self: Window, on: bool) void {
        if (self.headless) return;
        if (@hasDecl(backend.Window, "setAlwaysOnTop")) self.inner.setAlwaysOnTop(on);
    }

    /// クリック透過（per-pixel。透明画素上のクリックを背後へ抜けさせる）を設定する（TASK-104）。
    /// backend 未対応・headless は no-op。イベント時のみ。
    pub fn setClickThrough(self: Window, on: bool) void {
        if (self.headless) return;
        if (@hasDecl(backend.Window, "setClickThrough")) self.inner.setClickThrough(on);
    }

    /// 終了メニューをポップアップする（TASK-104。選択時に window の event queue に quit を積む）。
    /// backend 未対応・headless は no-op。イベント時のみ。
    pub fn showQuitMenu(self: Window) void {
        if (self.headless) return;
        if (@hasDecl(backend.Window, "showQuitMenu")) self.inner.showQuitMenu();
    }

    /// OS のモーダルループ（ライブリサイズ等）中に backend が 1 フレームの描画を app へ要求する
    /// opt-in 登録（TASK-23.1）。未登録時は backend が何も呼ばず従来挙動。
    /// harness 有効時（VP_HARNESS_*）および headless 時は登録自体をしない（no-op）。
    /// 再入ガードは facade の `redrawWrapper` に集約（コールバック中の再コールバックを遮断）。
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: RedrawFn) void {
        if (self.headless or harness.isEnabled()) return;
        redraw_guard = .{ .ctx = ctx, .cb = cb, .in_callback = false };
        self.inner.setRedrawCallback(@ptrCast(&redraw_guard), redrawWrapper);
    }

    /// 指定 index のゲームパッド状態を取得する（ポーリング主軸。ADR-009 / TASK-80.1・80.2）。
    /// harness 有効時（headless 含む）は facade の 5 つ目のチョークポイントとして
    /// `harness.getGamepadState` へ委譲し、`inject gamepad_connect/button/axis` の注入 state を返す
    /// （実 backend の有無・opt-in 状態に関わらず synthetic state を返す。TASK-80.1 の決定を継承）。
    /// 非 harness 時は macOS かつ `build_options.enable_gamepad`（TASK-80.2 opt-in 化。audio の
    /// `link_audio` と対称で、exe ごとに build.zig が opt-in する）のときだけ実 backend
    /// （GameController framework）へ分岐する。他 backend（Linux/Windows）や opt-in 無効の macOS exe は
    /// `null` を返すスタブのまま（`builtin.os.tag == .macos` と `build_options.enable_gamepad` は
    /// いずれも comptime-known 条件のため unselected 分岐は解析されない。本 facade の `sleep()`/`win_sleep`
    /// と同じ idiom で、Linux/Windows の `Window` に `getGamepadState` を実装させる必要が無く、opt-in
    /// 無効の macOS exe も GameController のシンボルを一切参照しない）。
    ///
    /// ホットパス宣言: フレーム毎に呼ばれる想定だが 4台×少数フィールドの固定長 copy
    /// （alloc/lock 無し）で全画素ループでも RT でもない。性能規約（SIMD 3点セット等）の
    /// 適用対象外（docs/adr/009 参照）。
    pub fn getGamepadState(self: Window, index: u8) ?GamepadState {
        if (harness.isEnabled() or harness.isHeadlessActive()) return harness.getGamepadState(index);
        if (builtin.os.tag != .macos) return null; // Linux/Windows backend は当面未実装（TASK-80.2 は macOS のみ）
        if (!build_options.enable_gamepad) return null; // opt-in 無効（TASK-80.2 opt-in 化）
        return self.inner.getGamepadState(index);
    }

    // ========================================================================
    // native menu (TASK-97.1)
    // ========================================================================

    /// この backend が native menu API を提供するかを返す。
    ///
    /// backend は module-level の任意 decl で実装する。未実装 backend と headless は
    /// 常に false。Command の slice は register/update 呼び出し中だけ有効でよく、
    /// backend が必要な分を copy する。
    pub fn nativeMenuAvailable(self: Window) bool {
        if (self.headless) return false;
        if (comptime @hasDecl(backend, "nativeMenuAvailable")) {
            return backend.nativeMenuAvailable(self.inner);
        }
        return false;
    }

    /// native menu を登録する。未実装 backend / headless では no-op。
    /// macOS のように app 単位のメニューバーを持つ backend では、window は契約上
    /// 無視して最後の登録が全体を差し替える。Windows 等は window 単位で扱う。
    pub fn registerMenu(self: Window, commands: []const Command) void {
        if (self.headless) return;
        if (comptime @hasDecl(backend, "registerMenu")) {
            backend.registerMenu(self.inner, commands);
        }
    }

    /// 登録済み native menu の enabled/checked 等を更新する。未実装 backend / headless は no-op。
    pub fn updateMenu(self: Window, commands: []const Command) void {
        if (self.headless) return;
        if (comptime @hasDecl(backend, "updateMenu")) {
            backend.updateMenu(self.inner, commands);
        }
    }

    /// 登録済み native menu を破棄する。未実装 backend / headless は no-op。
    pub fn destroyMenu(self: Window) void {
        if (self.headless) return;
        if (comptime @hasDecl(backend, "destroyMenu")) {
            backend.destroyMenu(self.inner);
        }
    }

    /// 呼び出し側の命名差を避けるための query alias。意味と契約は nativeMenuAvailable と同じ。
    pub const supportsNativeMenus = nativeMenuAvailable;

    /// IME composition preedit 本文を buf へ書く（TASK-79.6.1）。
    /// headless / 非対応 backend は常に空（text 0 長・revision/cursor 0）。
    ///
    /// **latest-wins 契約（親 TASK-79.6 codex 収束）**: snapshot は常に「現在の」未確定状態。
    /// 同一 poll 内の複数 `composition_changed` は最新 snapshot に潰れる。event の `revision` は
    /// 取りこぼし検知用で、過去 revision の snapshot は取得できない。
    ///
    /// ホットパス宣言: イベント時のみ（描画前の preedit 読み。フレーム毎全画素でも RT でもない）。
    pub fn getCompositionSnapshot(self: Window, buf: []u8) CompositionSnapshot {
        if (harness.isEnabled()) return harness.getCompositionSnapshot(buf);
        if (self.headless) return .{ .text = buf[0..0], .revision = 0, .cursor = 0 };
        return self.inner.getCompositionSnapshot(buf);
    }

    /// IME 候補窓の caret 基準 rect を framebuffer pixel・content 左上原点で供給する。
    /// headless / 未対応 backend は no-op。レイアウト変化時などイベント時のみ呼ぶ。
    pub fn setCompositionRect(self: Window, x: i32, y: i32, w: i32, h: i32) void {
        if (self.headless) return;
        if (comptime @hasDecl(backend.Window, "setCompositionRect")) {
            self.inner.setCompositionRect(x, y, w, h);
        }
    }

    /// TASK-142: テキスト編集ウィジェットのフォーカス有無を platform へ伝える汎用プリミティブ
    /// （SDL の StartTextInput/StopTextInput 相当。`setCompositionRect` と対になる）。
    /// active=false の間は IME/composition を経路から外すので、IME 有効中でも修飾なし英字キーが
    /// ショートカットとして届く。**冪等**なので consumer は毎フレーム focus 状態に追従して呼んでよい
    /// （実効経路が変わらなければ副作用なし。変わるときのみ composition 破棄等が走る）。headless は no-op。
    /// 将来の Linux/Windows 実装も「毎フレーム安全な冪等 setter（内部で変化検出）」であること。
    /// backend 実装は `@hasDecl` gate で opt-in: 現在は macOS（objc/swift/metal）のみ実装。
    /// Linux(XIM/ibus/text-input-v3)・Windows(IMM/WM_IME) は IME composition 実装時にこのメソッドを
    /// backend Window に足せば、facade も consumer も無改修で有効化される（未実装 backend は no-op）。
    pub fn setTextInputActive(self: Window, active: bool) void {
        if (self.headless) return;
        if (comptime @hasDecl(backend.Window, "setTextInputActive")) {
            self.inner.setTextInputActive(active);
        }
    }
};

pub fn init() Error!void {
    // headless 判定を先に確定させる（env 読取のみ・副作用無し）。headless なら backend.init() 自体を
    // スキップする（display 接続を一切しない。TASK-32.4 P4）。非 headless は従来通り backend→transport の順を保つ。
    // copilot は TASK-62.5.2 §3b の順序: harness.parseConfig → copilot.parseConfig → backend init →
    // harness.startTransport → copilot.startTransport（排他は env 存在ベースで parseConfig 時点に確定）。
    harness.parseConfig();
    copilot.parseConfig();
    if (!harness.isHeadlessActive()) {
        try backend.init();
    }
    harness.startTransport();
    copilot.startTransport();
    // netsync session → copilot operate 拒否（callback は initFromEnv の enableRouter より前に登録）。
    netsync.setSessionStateCallback(copilot.setNetsyncSessionActive);
    // netsync は headless 分岐でも起動（env 未設定なら initFromEnv 即 return。TASK-62.3.2）。
    netsync.initFromEnv();
    // 観測 probe（TASK-62.3.4）。有効時のみ。netsync→harness 逆依存を避けるため platform から登録。
    if (netsync.isEnabled()) {
        harness.registerProbe(.{
            .name = "netsync",
            .ctx = @ptrFromInt(1),
            .ext = "json",
            .desc = "netsync role/peers/last_seq/pending/awaiting_sync/last_reject",
            .digest = netsync.probeDigest,
            .snapshot = netsync.probeSnapshot,
        });
    }
}

pub fn shutdown() void {
    // app_runtime の defer は登録順と逆に実行されるため App.deinit が先に走る。
    // 借用先の App 解放後に netsync/copilot が executor を deref しないよう、先に借用を drop する。
    netsync.forgetSharedExecutor();
    copilot.forgetSharedExecutor();
    netsync.shutdown(); // main thread で setRouter(null)。disabled 時は no-op
    copilot.stopTransport(); // 接続中 stream → listener の順に close（disabled 時は no-op）
    if (harness.isHeadlessActive()) return; // backend.init() を呼んでいないので shutdown も呼ばない
    backend.shutdown();
}

pub fn getTime() f64 {
    // isHeadlessActive() も見るのは意図的: headless は backend.init() 自体をスキップしているため、
    // script 読込失敗等で transport が最終的に `.disabled`（isEnabled()==false）になっても
    // backend.getTime() を呼んではいけない（未初期化 backend 参照になる）。仮想クロックは
    // backend に依存せず常に安全に呼べる。
    if (harness.isEnabled() or harness.isHeadlessActive()) return harness.now();
    return backend.getTime();
}

/// Dock アイコン / メニューバーの表示を切替える（TASK-104。アプリ全体・window 非依存）。
/// visible=false で常駐アプリらしくする（macOS=accessory policy）。backend 未対応・headless は no-op。
/// ホットパス宣言: 初期化/イベント時のみ。
pub fn setDockVisible(visible: bool) void {
    if (harness.isHeadlessActive()) return;
    if (@hasDecl(backend, "setDockVisible")) backend.setDockVisible(visible);
}

/// ファイル保存ダイアログ。headless 時は backend が未初期化（native panel / zenity を呼べない）ため
/// 即 `error.DialogFailed` を返す（TASK-32.4 P4）。
pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    if (harness.isHeadlessActive()) return error.DialogFailed;
    return backend.saveFileDialog(gpa, io, opts);
}

/// ファイルを開くダイアログ。headless 時は即 `error.DialogFailed`（`saveFileDialog` と同じ理由）。
/// wasm では非同期: 未 pick 時 `error.DialogPending`（次 frame で再試行。TASK-73.3）。
pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    if (harness.isHeadlessActive()) return error.DialogFailed;
    return backend.openFileDialog(gpa, io, opts);
}

// ============================================================================
// System clipboard（TASK-73.3 wasm 色 clipboard。native は no-op / 未実装）
// TASK-120 の setClipboardText/getClipboardText（OS テキスト）とは別経路。混在させない。
// ============================================================================

/// システム clipboard へ text を書く。backend 未実装時は no-op。
pub fn clipboardWrite(text: []const u8) void {
    if (comptime @hasDecl(backend, "clipboardWrite")) {
        backend.clipboardWrite(text);
    }
}

/// システム clipboard の text を非同期要求。backend 未実装時は no-op。
pub fn clipboardRequestPaste() void {
    if (comptime @hasDecl(backend, "clipboardRequestPaste")) {
        backend.clipboardRequestPaste();
    }
}

/// 届いていれば text を返し消費する。未着・未実装は null。
pub fn clipboardTakePaste() ?[]const u8 {
    if (comptime @hasDecl(backend, "clipboardTakePaste")) {
        return backend.clipboardTakePaste();
    }
    return null;
}

// ============================================================================
// OS テキストクリップボード（TASK-120）
// ============================================================================
//
// ホットパス宣言: イベント時のみ（Cmd+C/X/V）。フレーム毎・RT では呼ばない。
// headless / unit test では固定長 in-memory fallback。通常 native runtime は backend
//（macOS objc=NSPasteboard）へ委譲する。

const MEMORY_CLIPBOARD_CAP: usize = 4096;

var memory_clipboard: [MEMORY_CLIPBOARD_CAP]u8 = undefined;
var memory_clipboard_len: usize = 0;
var memory_clipboard_set: bool = false;

fn useMemoryClipboard() bool {
    return builtin.is_test or harness.isHeadlessActive();
}

fn utf8TruncateLen(text: []const u8, max: usize) usize {
    var n = @min(text.len, max);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) : (n -= 1) {}
    return n;
}

/// テスト間で in-memory clipboard を初期化する（`builtin.is_test` 時のみ有効）。
pub fn resetClipboardForTest() void {
    if (!builtin.is_test) return;
    memory_clipboard_len = 0;
    memory_clipboard_set = false;
}

/// UTF-8 text を OS clipboard へ書く。未対応 backend は no-op。
pub fn setClipboardText(text: []const u8) void {
    if (useMemoryClipboard()) {
        const n = utf8TruncateLen(text, MEMORY_CLIPBOARD_CAP);
        @memcpy(memory_clipboard[0..n], text[0..n]);
        memory_clipboard_len = n;
        memory_clipboard_set = true;
        return;
    }
    if (comptime @hasDecl(backend, "setClipboardText")) {
        backend.setClipboardText(text);
    }
}

/// OS clipboard の UTF-8 text を caller 所有 buffer へコピーする。
/// null = 未対応 / 未設定 / 失敗。空文字列は `buf[0..0]`。容量超過は UTF-8 境界で切り詰め。
pub fn getClipboardText(buf: []u8) ?[]const u8 {
    if (useMemoryClipboard()) {
        if (!memory_clipboard_set) return null;
        const n = utf8TruncateLen(memory_clipboard[0..memory_clipboard_len], buf.len);
        @memcpy(buf[0..n], memory_clipboard[0..n]);
        return buf[0..n];
    }
    if (comptime @hasDecl(backend, "getClipboardText")) {
        return backend.getClipboardText(buf);
    }
    return null;
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
// custom action（TASK-62.1 → TASK-62.3.1 で action_registry へ分離）
//
// app が `platform.registerAction(.{ .name, .ctx, .run })` で高レベル操作を opt-in 登録する。
// probe（read）に対称な操作（write）口。参照先は `action_registry`（harness 経由の同一インスタンス）。
// harness/action_registry 無効時（env 未設定）は registerAction が no-op。
// framework は action の中身を解釈しない（probe と同じ不変条件）。
// ============================================================================
pub const Action = harness.action_registry.Action;
pub const NetworkPolicy = harness.action_registry.NetworkPolicy;
pub const registerAction = harness.action_registry.registerAction;
/// action 失敗時の structured error（code + suggested_next_action）。opt-in。TASK-62.5.9。
pub const setActionErrorDetail = harness.action_registry.setActionErrorDetail;

pub const StateSync = netsync.StateSync;
/// netsync join 時の document/patch 同期アダプタ登録（無効時も保存のみ・常に呼んでよい）。
pub const registerStateSync = netsync.registerStateSync;

/// netsync session が有効か（host/client 接続中）。キーボード undo/redo の経路切替用（TASK-62.3.5）。
pub const netsyncActive = netsync.isEnabled;

/// action を netsync router 経由で実行（router 未設定時は dispatch 等価）。
pub const routeAction = harness.action_registry.routeLocalAction;

// ============================================================================
// command model（TASK-62.5.1/62.5.3）
//
// app が CommandLog + Executor を所有して「誰が（ActorId）・何を実行したか」を記録する型群。
// command.zig は std のみ（platform/harness 非依存）だが、型の単一 instance 共有のため
// harness module 経由で再エクスポートする。apps は `kit.platform.command` で届く
// （command は std のみなので層規約上の追加依存は生じない）。
// ============================================================================
pub const command = harness.command;
/// app の `dispatchCommand(id)` を Executor/router へ接続する adapter 契約。
pub const command_adapter = harness.command;

/// Co-pilot / netsync の共有 executor を設定する（各 setSharedExecutor への委譲。TASK-62.5.3）。
/// 設定時、copilot transport の `action` は app 側 wrapper（executor 経由の記録を一元化）へ
/// 直 dispatch し、`begin_tx`/`end_tx`/`cancel_tx` はこの executor に対して操作する。
/// **harness 無効・copilot 無効時も呼んでよい**（module 変数の代入のみの no-op 規約）。
/// Executor は caller 所有の借用であり、platform.shutdown が teardown 時に借用を drop するため
/// app 側の明示的な登録解除は不要。ただし platform.shutdown より後まで Executor を生かし続けてはならない。
pub fn setCommandExecutor(exec: ?*command.Executor) void {
    copilot.setSharedExecutor(exec);
    netsync.setSharedExecutor(exec); // remote COMMIT 適用（no_record）。未設定時 netsync は dispatch fallback
}

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
/// wasm では no-op（rAF がペーシング。nanosleep 参照を comptime で除外。TASK-73.1）。
const sleep_impl = if (builtin.cpu.arch.isWasm()) struct {
    fn call(_: u64) void {}
} else struct {
    fn call(nanoseconds: u64) void {
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
};

pub fn sleep(nanoseconds: u64) void {
    sleep_impl.call(nanoseconds);
}

/// フレーム毎の main loop ウェイト（TASK-32.4 P4）。harness 有効時（headless に限らず replay/live とも）は
/// **no-op**（フレーム進行は `pollGate` が gate し、時刻は仮想クロックなので実時間 sleep は純粋な待ち損＝
/// replay 速度の律速要因）。harness 無効時は `sleep()` と同じ。main/examples の frame-wait 呼び出しは
/// これに置き換える（`sleep()` 自体はフレームウェイト以外の用途向けに残す）。
pub fn frameDelay(nanoseconds: u64) void {
    // isHeadlessActive() も見る（getTime()/audio.open() と同じ理由）。headless 指定時に transport が
    // 最終的に disabled でも実時間 sleep で main loop を止めない（pollGate が既に false を返し
    // ループを終える構成なので実害は薄いが、判定を統一しておく）。
    if (harness.isEnabled() or harness.isHeadlessActive()) return;
    sleep(nanoseconds);
}
