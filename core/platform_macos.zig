//! macOS native platform backend
//!
//! C API (`platform/platform.h`) を Zig の高レベル interface に変換するレイヤ。
//! `@cImport` を内部に閉じ込め、caller には Zig native な型のみを公開する。
//!
//! 公開型（KeyCode / Event 等）は `platform_types.zig` を正準ソースとし、本ファイルは
//! C 値からそれらを構築する変換層と、`Window`/`Framebuffer`・関数群を提供する。

const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform_types");
const command_types = @import("command_types");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("platform.h");
});

// platform.h は旧 C 公開面を維持し、quit cancel はこの backend 専用の追加 ABI として
// native 実装（objc/swift/metal）が同名 symbol を提供する。
extern fn platform_cancel_quit(window: *c.PlatformWindow) void;

/// TASK-122: メニュー C symbol 参照は enable_menu かつ macOS native backend
///（objc/swift/metal）のときだけ。非使用 exe の undefined symbol を構造的に防ぐ。
const menu_c_abi = build_options.enable_menu and (std.mem.eql(u8, build_options.platform_backend, "objc") or
    std.mem.eql(u8, build_options.platform_backend, "swift") or
    std.mem.eql(u8, build_options.platform_backend, "metal"));

const MenuC = if (menu_c_abi) struct {
    extern fn platform_menu_available() bool;
    extern fn platform_register_menu(window: ?*c.PlatformWindow, items: [*]const c.PlatformMenuItem, count: u32) void;
    extern fn platform_update_menu(window: ?*c.PlatformWindow, items: [*]const c.PlatformMenuItem, count: u32) void;
    extern fn platform_destroy_menu(window: ?*c.PlatformWindow) void;
} else struct {};

/// TASK-120: テキスト clipboard C symbol は Objective-C backend のみ。
/// Swift/Metal は未実装 stub。unit test（`builtin.is_test`）では C symbol を参照しない
/// （facade の in-memory fallback が担当。リンク時 undefined を防ぐ）。
const clipboard_c_abi = !builtin.is_test and std.mem.eql(u8, build_options.platform_backend, "objc");

const ClipboardC = if (clipboard_c_abi) struct {
    extern fn platform_set_clipboard_text(utf8: [*]const u8, len: u32) void;
    extern fn platform_get_clipboard_text(out: [*]u8, cap: u32, out_len: *u32) bool;
} else struct {};

// 共有型のエイリアス（platform_types.zig が正準。signature 記述を簡潔にするため）
const Error = types.Error;
const KeyCode = types.KeyCode;
const ModifierFlags = types.ModifierFlags;
const MouseButton = types.MouseButton;
const MouseButtons = types.MouseButtons;
const KeyEvent = types.KeyEvent;
const CharEvent = types.CharEvent;
const CompositionEvent = types.CompositionEvent;
const CompositionPhase = types.CompositionPhase;
const CompositionSnapshot = types.CompositionSnapshot;
const MouseEvent = types.MouseEvent;
const ScrollEvent = types.ScrollEvent;
const Event = types.Event;
const EventStats = types.EventStats;
const SaveDialogOptions = types.SaveDialogOptions;
const OpenDialogOptions = types.OpenDialogOptions;
const DialogError = types.DialogError;
const CursorShape = types.CursorShape;
const GamepadState = types.GamepadState;
const GamepadButtons = types.GamepadButtons;
const GamepadInfo = types.GamepadInfo;
const GamepadDisconnect = types.GamepadDisconnect;
const GAMEPAD_NAME_MAX = types.GAMEPAD_NAME_MAX;
const Command = command_types.Command;

pub fn init() Error!void {
    if (!c.platform_init()) return error.InitFailed;
}

pub fn shutdown() void {
    c.platform_shutdown();
}

pub fn getTime() f64 {
    return c.platform_get_time();
}

/// Dock アイコン / メニューバーの表示を切替える（TASK-104。アプリ全体・window 非依存）。
/// visible=false で accessory（常駐アプリらしくする）。イベント/初期化時のみ。
pub fn setDockVisible(visible: bool) void {
    c.platform_set_dock_visible(visible);
}

// ============================================================================
// C 値 → 共有型 への変換
// ============================================================================

inline fn keyFromC(raw: c.PlatformKeyCode) KeyCode {
    return @enumFromInt(@as(c_int, raw));
}

inline fn buttonFromC(raw: c.PlatformMouseButton) MouseButton {
    return @enumFromInt(@as(c_int, @intCast(raw)));
}

inline fn makeKeyEvent(ev: c.PlatformEvent) KeyEvent {
    return .{
        .key = keyFromC(ev.payload.keyboard.key),
        .is_repeat = ev.payload.keyboard.is_repeat,
        .modifiers = ModifierFlags.fromC(ev.payload.keyboard.modifiers),
    };
}

inline fn makeMouseEvent(ev: c.PlatformEvent) MouseEvent {
    return .{
        .x = ev.payload.mouse.x,
        .y = ev.payload.mouse.y,
        .button = buttonFromC(ev.payload.mouse.button),
        .buttons = MouseButtons.fromC(ev.payload.mouse.buttons_mask),
        .modifiers = ModifierFlags.fromC(ev.payload.mouse.modifiers),
    };
}

inline fn makeScrollEvent(ev: c.PlatformEvent) ScrollEvent {
    return .{
        .x = ev.payload.scroll.x,
        .y = ev.payload.scroll.y,
        .dx = ev.payload.scroll.dx,
        .dy = ev.payload.scroll.dy,
        .is_precise = ev.payload.scroll.is_precise,
        .buttons = MouseButtons.fromC(ev.payload.scroll.buttons_mask),
        .modifiers = ModifierFlags.fromC(ev.payload.scroll.modifiers),
    };
}

inline fn makeCharEvent(ev: c.PlatformEvent) CharEvent {
    return .{
        .codepoint = ev.payload.character.codepoint,
        .modifiers = ModifierFlags.fromC(ev.payload.character.modifiers),
    };
}

inline fn makeCompositionEvent(ev: c.PlatformEvent) CompositionEvent {
    return .{
        .revision = ev.payload.composition.revision,
        .phase = @as(CompositionPhase, @enumFromInt(ev.payload.composition.phase)),
        .cursor = ev.payload.composition.cursor,
    };
}

inline fn isFacadeSkipEvent(raw: c.PlatformEventType) bool {
    return raw == c.PLATFORM_EVENT_NONE;
}

test "macOS facade NONE skip: FIFO 順を保ったまま wrap 境界を越える" {
    try std.testing.expect(isFacadeSkipEvent(c.PLATFORM_EVENT_NONE));
    try std.testing.expect(!isFacadeSkipEvent(c.PLATFORM_EVENT_KEY_DOWN));
    var index: usize = 254;
    index = (index + 1) % 256;
    try std.testing.expectEqual(@as(usize, 255), index);
    index = (index + 1) % 256;
    try std.testing.expectEqual(@as(usize, 0), index);
    index = (index + 1) % 256;
    try std.testing.expectEqual(@as(usize, 1), index);
}

/// C の `gamepad.name`（32byte+NUL固定バッファ）を `GamepadInfo.name_buf` へコピーする（TASK-80.2）。
/// `strlen` 相当で NUL 終端までを有効長とし、`GAMEPAD_NAME_MAX` を超える分は切り詰める
/// （backend 側が既に切り詰め済みのため通常は発生しない。防御的にここでも境界を守る）。
inline fn makeGamepadInfo(ev: c.PlatformEvent) GamepadInfo {
    var info = GamepadInfo{ .index = @intCast(ev.payload.gamepad.index) };
    const raw_name: [*:0]const u8 = @ptrCast(&ev.payload.gamepad.name);
    const len = @min(std.mem.len(raw_name), GAMEPAD_NAME_MAX);
    @memcpy(info.name_buf[0..len], raw_name[0..len]);
    info.name_len = @intCast(len);
    return info;
}

inline fn makeGamepadDisconnect(ev: c.PlatformEvent) GamepadDisconnect {
    return .{ .index = @intCast(ev.payload.gamepad.index) };
}

var key_trace_state: ?bool = null;

fn keyTraceEnabled() bool {
    if (key_trace_state) |enabled| return enabled;
    const enabled = if (std.c.getenv("VP_KEY_TRACE")) |value|
        std.mem.eql(u8, std.mem.span(value), "1")
    else
        false;
    key_trace_state = enabled;
    return enabled;
}

fn traceFacadeEvent(ev: Event) void {
    if (!keyTraceEnabled()) return;
    switch (ev) {
        .key_down => |k| std.debug.print("[key-trace] facade key_down key={d} repeat={d} mods=0x{X}\n", .{ @intFromEnum(k.key), @intFromBool(k.is_repeat), k.modifiers.toC() }),
        .key_up => |k| std.debug.print("[key-trace] facade key_up key={d} mods=0x{X}\n", .{ @intFromEnum(k.key), k.modifiers.toC() }),
        .char_input => |ch| std.debug.print("[key-trace] facade char_input cp=U+{X} mods=0x{X}\n", .{ ch.codepoint, ch.modifiers.toC() }),
        .composition_changed => |co| std.debug.print("[key-trace] facade composition phase={s} rev={d} cursor={d}\n", .{ @tagName(co.phase), co.revision, co.cursor }),
        else => {},
    }
}

// ============================================================================
// ライブリサイズ redraw トランポリン（TASK-23.1）
// ============================================================================
//
// C ABI の `PlatformRedrawCallback` は `callconv(.c)` が必要なため、facade から渡された
// Zig `RedrawFn` を module-level に保持し、C トランポリンから呼ぶ。単一ウィンドウ前提。

pub const RedrawFn = *const fn (ctx: *anyopaque) void;

var redraw_trampoline: struct {
    ctx: *anyopaque = undefined,
    cb: ?RedrawFn = null,
} = .{};

fn macosRedrawTrampoline(userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const cb = redraw_trampoline.cb orelse return;
    cb(redraw_trampoline.ctx);
}

// ============================================================================
// Window / Framebuffer
// ============================================================================

pub const Window = struct {
    handle: *c.PlatformWindow,

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        const w = c.platform_create_window(
            @intCast(width),
            @intCast(height),
            title.ptr,
            null,
            null,
        ) orelse return error.WindowCreationFailed;
        return .{ .handle = w };
    }

    /// 本物のフルスクリーンウィンドウを作成する（TASK-100.1）。facade の Window.createFullscreen が
    /// `@hasDecl` でこれを検出して使う。通常ウィンドウを作ってから `platform_enter_fullscreen`
    /// （NSWindow toggleFullScreen:）でネイティブフルスクリーン化する。実サイズは画面解像度に
    /// なり、framebuffer は既存の setFrameSize 経路で追従する（fb.width/height に反映）。
    /// 初期サイズは toggle 前の一瞬だけ有効なプレースホルダ。
    pub fn createFullscreen(title: [:0]const u8) Error!Window {
        const w = c.platform_create_window(1280, 720, title.ptr, null, null) orelse return error.WindowCreationFailed;
        c.platform_enter_fullscreen(w);
        return .{ .handle = w };
    }

    /// 透過 / borderless / 初期位置オプション付きでウィンドウを作成する（TASK-104 / TASK-117）。
    /// facade の Window.createWithOptions が `@hasDecl` でこれを検出して使う。unknown flags は
    /// C 側が NULL を返す（→ WindowCreationFailed）。透過は premultiplied alpha 前提。
    /// ホットパス宣言: 初期化時のみ（ウィンドウ生成 1 回）。
    pub fn createWithOptions(width: u32, height: u32, title: [:0]const u8, opts: types.WindowOptions) Error!Window {
        var flags: u32 = 0;
        if (opts.transparent) flags |= c.PLATFORM_WINDOW_TRANSPARENT;
        if (opts.borderless) flags |= c.PLATFORM_WINDOW_BORDERLESS;
        var copts = c.PlatformWindowOptions{ .flags = flags, .reserved = 0, .x = 0, .y = 0 };
        if (opts.position) |pos| {
            copts.flags |= c.PLATFORM_WINDOW_POSITION;
            copts.x = pos.x;
            copts.y = pos.y;
        }
        const w = c.platform_create_window_ex(
            @intCast(width),
            @intCast(height),
            title.ptr,
            null,
            null,
            &copts,
        ) orelse return error.WindowCreationFailed;
        return .{ .handle = w };
    }

    /// 表示中の OS ウィンドウタイトルを更新する。イベント境界でのみ呼ぶ。
    pub fn setTitle(self: Window, title: [:0]const u8) void {
        c.platform_set_title(self.handle, title.ptr);
    }

    /// 直近のポインタ押下から OS の対話的ウィンドウ移動を開始する（TASK-104）。イベント時のみ。
    pub fn beginDrag(self: Window) void {
        c.platform_begin_window_drag(self.handle);
    }

    /// 常に最前面（always-on-top）を設定する（TASK-104）。イベント時のみ。
    pub fn setAlwaysOnTop(self: Window, on: bool) void {
        c.platform_set_always_on_top(self.handle, on);
    }

    /// クリック透過（per-pixel。透明画素上のクリックを背後へ抜けさせる）を設定する（TASK-104）。
    pub fn setClickThrough(self: Window, on: bool) void {
        c.platform_set_click_through(self.handle, on);
    }

    /// 終了メニューをポップアップする（TASK-104。選択時に window の event queue に quit を積む）。
    pub fn showQuitMenu(self: Window) void {
        c.platform_show_quit_menu(self.handle);
    }

    pub fn destroy(self: Window) void {
        c.platform_destroy_window(self.handle);
    }

    /// close delegate が積んだ quit request を consumer がキャンセルする。
    /// ホットパス宣言: quit/close イベント時のみ。
    pub fn cancelQuit(self: Window) void {
        platform_cancel_quit(self.handle);
    }

    pub fn pollEvents(self: Window) bool {
        return c.platform_poll_events(self.handle);
    }

    pub fn nextEvent(self: Window) ?Event {
        while (true) {
            var ev: c.PlatformEvent = undefined;
            if (!c.platform_get_event(self.handle, &ev)) return null;
            if (isFacadeSkipEvent(ev.type)) continue;
            const mapped: ?Event = switch (ev.type) {
                c.PLATFORM_EVENT_QUIT => .quit,
                c.PLATFORM_EVENT_KEY_DOWN => Event{ .key_down = makeKeyEvent(ev) },
                c.PLATFORM_EVENT_KEY_UP => Event{ .key_up = makeKeyEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_MOVE => Event{ .mouse_move = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_DOWN => Event{ .mouse_down = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_UP => Event{ .mouse_up = makeMouseEvent(ev) },
                c.PLATFORM_EVENT_MOUSE_SCROLL => Event{ .mouse_scroll = makeScrollEvent(ev) },
                c.PLATFORM_EVENT_CHAR_INPUT => Event{ .char_input = makeCharEvent(ev) },
                c.PLATFORM_EVENT_GAMEPAD_CONNECTED => Event{ .gamepad_connected = makeGamepadInfo(ev) },
                c.PLATFORM_EVENT_GAMEPAD_DISCONNECTED => Event{ .gamepad_disconnected = makeGamepadDisconnect(ev) },
                c.PLATFORM_EVENT_COMPOSITION => Event{ .composition_changed = makeCompositionEvent(ev) },
                c.PLATFORM_EVENT_MENU_COMMAND => Event{ .menu_command = ev.payload.menu.command_id },
                else => null,
            };
            if (mapped) |event| {
                traceFacadeEvent(event);
                return event;
            }
        }
    }

    /// IME composition preedit 本文を buf へ書く（TASK-79.6.1）。空なら text は 0 長。
    /// latest-wins: 常に現在状態。event.revision は取りこぼし検知用で過去 revision は取得不可。
    pub fn getCompositionSnapshot(self: Window, buf: []u8) CompositionSnapshot {
        var meta: c.PlatformCompositionMeta = .{
            .revision = 0,
            .cursor = 0,
            .len = 0,
        };
        const n = c.platform_get_composition_snapshot(
            self.handle,
            if (buf.len > 0) buf.ptr else null,
            @intCast(buf.len),
            &meta,
        );
        const len: usize = @min(@as(usize, n), buf.len);
        return .{
            .text = buf[0..len],
            .revision = meta.revision,
            .cursor = meta.cursor,
        };
    }

    /// IME 候補窓の caret 基準 rect を framebuffer pixel で供給する（イベント時のみ）。
    pub fn setCompositionRect(self: Window, x: i32, y: i32, w: i32, h: i32) void {
        c.platform_set_composition_rect(self.handle, x, y, w, h);
    }

    pub fn getEventStats(self: Window) EventStats {
        var s: c.PlatformEventStats = undefined;
        c.platform_get_event_stats(self.handle, &s);
        return .{
            .mouse_move_merge_count = s.mouse_move_merge_count,
            .mouse_scroll_merge_count = s.mouse_scroll_merge_count,
            .event_drop_count = s.event_drop_count,
        };
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        var w: c_int = 0;
        var h: c_int = 0;
        const px = c.platform_lock_framebuffer(self.handle, &w, &h) orelse return null;
        const len = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
        return .{
            .pixels = px[0..len],
            .width = @intCast(w),
            .height = @intCast(h),
            .window_handle = self.handle,
        };
    }

    pub fn present(self: Window) void {
        c.platform_present(self.handle);
    }

    /// カーソル形状を設定する（TASK-75.1）。イベント時のみ呼ぶ想定（性能規約の対象外）。
    pub fn setCursor(self: Window, shape: CursorShape) void {
        c.platform_set_cursor(self.handle, @intFromEnum(shape));
    }

    /// ライブリサイズ再描画コールバック登録（TASK-23.1）。
    /// facade から渡された Zig 関数を C トランポリン経由で native へ渡す。
    /// 単一ウィンドウ前提（module-level に `{ctx, cb}` を保持）。
    pub fn setRedrawCallback(self: Window, ctx: *anyopaque, cb: RedrawFn) void {
        redraw_trampoline = .{ .ctx = ctx, .cb = cb };
        c.platform_set_redraw_callback(self.handle, macosRedrawTrampoline, null);
    }

    /// destroy 用の private clear 経路（public API に null を通さない。TASK-23.1 実装メモ）。
    pub fn clearRedrawCallback(self: Window) void {
        redraw_trampoline = .{};
        c.platform_set_redraw_callback(self.handle, null, null);
    }

    /// 指定 index のゲームパッド状態を取得する（GameController framework 経由。TASK-80.2。ADR-009）。
    /// 未接続/index範囲外は null。
    ///
    /// ホットパス宣言: フレーム毎に呼ばれる想定だが 4台×少数フィールドの固定長 copy（alloc/lock 無し）
    /// で全画素ループでも RT でもないため性能規約の適用対象外（ADR-009 参照）。
    pub fn getGamepadState(self: Window, index: u8) ?GamepadState {
        var s: c.PlatformGamepadState = undefined;
        if (!c.platform_get_gamepad_state(self.handle, @intCast(index), &s)) return null;
        return .{
            .buttons = GamepadButtons.fromC(s.buttons_mask),
            .left_stick = .{ .x = s.left_stick_x, .y = s.left_stick_y },
            .right_stick = .{ .x = s.right_stick_x, .y = s.right_stick_y },
            .left_trigger = s.left_trigger,
            .right_trigger = s.right_trigger,
        };
    }

    // ========================================================================
};

// ============================================================================
// native menu (TASK-97.3)
// ============================================================================
//
// ホットパス宣言: 登録・状態更新は初期化時/状態変更イベント時のみ。選択はイベント時のみ。
// 性能規約の適用対象外。
//
// ⚠ facade（core/platform.zig）は `@hasDecl(backend, "nativeMenuAvailable")` で
// **module-level decl** を探して dispatch する（97.1 契約。doc comment に明記）。
// Window struct のメソッドにすると comptime 検査が silently false になり、
// 全ビルド緑のまま native メニューが永遠に無効化される（2026-07-17 実機で発覚した実バグ。
// headless E2E は fallback が期待値のため検出不能だった）。module-level から動かさないこと。

pub fn nativeMenuAvailable(win: Window) bool {
    _ = win;
    if (comptime !menu_c_abi) return false;
    return MenuC.platform_menu_available();
}

// ============================================================================
// window geometry (TASK-117)
// ============================================================================
//
// ホットパス宣言: ウィンドウ生成時 / 終了時 shutdown / harness digest 観測時のみ。
//
// ⚠ getGeometry も nativeMenuAvailable と同じく **module-level decl** 必須。
// Window struct メソッドにすると facade の `@hasDecl(backend, "getGeometry")` が
// silently false になり、常に 0x0/null を返す（TASK-97.3 と同型の配線バグ）。

pub fn getGeometry(win: Window) types.WindowGeometry {
    var geo: c.PlatformWindowGeometry = .{
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 0,
        .flags = 0,
    };
    c.platform_get_window_geometry(win.handle, &geo);
    return .{
        .position = if ((geo.flags & c.PLATFORM_GEOMETRY_POSITION_VALID) != 0)
            .{ .x = geo.x, .y = geo.y }
        else
            null,
        .size = .{ .width = geo.width, .height = geo.height },
    };
}

pub fn registerMenu(win: Window, commands: []const Command) void {
    if (comptime !menu_c_abi) return;
    var scratch: MenuScratch = .{};
    const items = scratch.fill(commands);
    MenuC.platform_register_menu(win.handle, items.ptr, @intCast(items.len));
}

pub fn updateMenu(win: Window, commands: []const Command) void {
    if (comptime !menu_c_abi) return;
    var scratch: MenuScratch = .{};
    const items = scratch.fill(commands);
    MenuC.platform_update_menu(win.handle, items.ptr, @intCast(items.len));
}

pub fn destroyMenu(win: Window) void {
    if (comptime !menu_c_abi) return;
    MenuC.platform_destroy_menu(win.handle);
}

/// Command → PlatformMenuItem 変換用の一時バッファ。
/// 文字列は呼び出し中のみ有効（backend が copy）。stack 固定長で alloc しない。
const MENU_SCRATCH_CAP = 64;
const MENU_STR_CAP = 256;

const MenuScratch = struct {
    items: [MENU_SCRATCH_CAP]c.PlatformMenuItem = undefined,
    titles: [MENU_SCRATCH_CAP][MENU_STR_CAP]u8 = undefined,
    labels: [MENU_SCRATCH_CAP][MENU_STR_CAP]u8 = undefined,

    fn fill(self: *MenuScratch, commands: []const Command) []const c.PlatformMenuItem {
        if (commands.len > MENU_SCRATCH_CAP) {
            std.log.warn("platform_macos menu: command count {d} exceeds MENU_SCRATCH_CAP={d}; truncating", .{
                commands.len,
                MENU_SCRATCH_CAP,
            });
        }
        const n = @min(commands.len, MENU_SCRATCH_CAP);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const cmd = commands[i];
            const title_z = copyZUtf8(&self.titles[i], cmd.menu.title);
            const label_z = copyZUtf8(&self.labels[i], cmd.label);
            self.items[i] = .{
                .command_id = cmd.id,
                .kind = if (cmd.kind == .separator) c.PLATFORM_MENU_KIND_SEPARATOR else c.PLATFORM_MENU_KIND_NORMAL,
                .top_menu = title_z,
                .label = label_z,
                .shortcut_key = if (cmd.shortcut) |sc| @intFromEnum(sc.key) else -1,
                .shortcut_mods = if (cmd.shortcut) |sc| sc.modifiers.toC() else 0,
                .enabled = if (cmd.enabled) 1 else 0,
                .checked = if (cmd.checked) 1 else 0,
            };
        }
        return self.items[0..n];
    }

    /// UTF-8 安全に NUL 終端へコピーする。バイト上限で切る場合はコードポイント境界へ戻す
    /// （継続バイト 0b10xxxxxx の途中切断 → ObjC stringWithUTF8String: nil を防ぐ）。
    fn copyZUtf8(buf: *[MENU_STR_CAP]u8, src: []const u8) [*:0]const u8 {
        const max = MENU_STR_CAP - 1;
        const capped = @min(src.len, max);
        var n = capped;
        // 末尾の継続バイトを捨てて lead 上へ戻す
        while (n > 0 and (src[n - 1] & 0xC0) == 0x80) n -= 1;
        // lead だけ残って不完全な多バイト列なら lead も捨てる
        if (n > 0) {
            const lead = src[n - 1];
            const need: usize = if (lead < 0x80)
                1
            else if (lead < 0xE0)
                2
            else if (lead < 0xF0)
                3
            else if (lead < 0xF8)
                4
            else
                1;
            if ((n - 1) + need > capped) n -= 1;
        }
        @memcpy(buf[0..n], src[0..n]);
        buf[n] = 0;
        return buf[0..n :0].ptr;
    }
};

/// Locked framebuffer view. `unlock` を 1 度だけ呼ぶ慣習で運用する
/// （`if (window.lockFramebuffer()) |fb| { defer fb.unlock(); ... }`）。
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    window_handle: *c.PlatformWindow,

    pub fn unlock(self: Framebuffer) void {
        c.platform_unlock_framebuffer(self.window_handle);
    }
};

// ============================================================================
// ファイル選択ダイアログ (TASK-24)
// ============================================================================
//
// 同期モーダル（app-modal）。**framebuffer lock 中には呼ばないこと**（caller 責任）。
// 戻り値は gpa 所有スライス（caller が gpa.free すること）。キャンセル時は null、
// メモリ確保失敗時は error.OutOfMemory。

/// 保存先をユーザーに選ばせる。
pub fn saveFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: SaveDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io; // macOS は native panel（io 不要）。全 OS 共通シグネチャのため受け取る。
    var c_opts: c.PlatformSaveDialogOptions = .{
        .default_name = if (opts.default_name) |s| s.ptr else null,
        .allowed_ext = if (opts.allowed_ext) |s| s.ptr else null,
    };
    const p = c.platform_save_file_dialog(&c_opts) orelse return null;
    return try dupePathAndFree(gpa, p);
}

/// 開くファイルをユーザーに選ばせる（単一選択・ファイルのみ）。
pub fn openFileDialog(gpa: std.mem.Allocator, io: std.Io, opts: OpenDialogOptions) (DialogError || std.mem.Allocator.Error)!?[]u8 {
    _ = io; // macOS は native panel（io 不要）。全 OS 共通シグネチャのため受け取る。
    var c_opts: c.PlatformOpenDialogOptions = .{
        .allowed_ext = if (opts.allowed_ext) |s| s.ptr else null,
    };
    const p = c.platform_open_file_dialog(&c_opts) orelse return null;
    return try dupePathAndFree(gpa, p);
}

/// C 側が確保したパス文字列を gpa 所有スライスへ複製し、C 側を必ず解放する。
/// dupe が OOM でも defer で platform_free_path を呼ぶので C 側はリークしない。
fn dupePathAndFree(gpa: std.mem.Allocator, p: [*c]u8) std.mem.Allocator.Error![]u8 {
    defer c.platform_free_path(p);
    return try gpa.dupe(u8, std.mem.span(p));
}

// ============================================================================
// OS テキストクリップボード (TASK-120)
// ============================================================================

/// UTF-8 text を OS clipboard へ書く。objc 以外は no-op。
pub fn setClipboardText(text: []const u8) void {
    if (comptime !clipboard_c_abi) return;
    ClipboardC.platform_set_clipboard_text(text.ptr, @intCast(text.len));
}

/// OS clipboard の UTF-8 text を caller buffer へコピーする。
/// 未対応 backend・文字列無し・失敗は null。空文字列は `buf[0..0]`。
pub fn getClipboardText(buf: []u8) ?[]const u8 {
    if (comptime !clipboard_c_abi) return null;
    if (buf.len == 0) return null;
    var out_len: u32 = 0;
    if (!ClipboardC.platform_get_clipboard_text(buf.ptr, @intCast(buf.len), &out_len)) return null;
    return buf[0..out_len];
}
