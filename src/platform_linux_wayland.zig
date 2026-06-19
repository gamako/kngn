//! Linux platform backend — Wayland 実装スケルトン（TASK-28.5.1）
//!
//! `src/platform_linux.zig`（dispatcher）が `build_options.platform_backend == "wayland"` のとき選ぶ。
//!
//! 本タスク（28.5.1）の到達点は **build 土台のみ**:
//!   - `@cImport` で wayland-client / xkbcommon / 生成 xdg-shell-client-protocol.h が compile できる。
//!   - build helper が wayland-client / xkbcommon を link し、生成 xdg-shell-protocol.c を exe に compile する
//!     （その .c が wl_proxy_* を参照するため wayland-client への link が成立する）。
//!   - 公開面（Window/Framebuffer/init/shutdown/getTime/dialog）が型として揃い、dispatcher 経由で
//!     `-Dplatform=wayland` のビルドが compile/link 段階まで通る。
//!
//! 実際の wl_display 接続 / registry bind / xdg_surface configure / wl_shm ダブルバッファ / 入力は
//! TASK-28.5.2 以降で実装する。現状の Window.create は `error.WindowCreationFailed` を返し、
//! 他メソッドは型を満たす最小値（no-op / null / zero）を返すだけ。
//! 設計の正は docs/plans/28.5-plan.md。

const std = @import("std");
const types = @import("platform_types.zig");
const common = @import("platform_linux_common.zig");
const build_options = @import("build_options");

// wayland-client.h を先に include（xdg-shell-client-protocol.h が wl_* 型を使うため順序が重要）。
// xkbcommon は keymap/modifier 用（実利用は 28.5.3）。xdg-shell-client-protocol.h は build 時に
// wayland-scanner が生成し、build helper が include path を通す。
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const Error = types.Error;
const Event = types.Event;
const EventStats = types.EventStats;

comptime {
    // 本ファイルは wayland 実装。dispatcher が build_options.platform_backend=="wayland" のときだけ
    // import する。誤って他 backend で取り込まれた場合に明確に落とす二重防御（28.5.1）。
    if (!std.mem.eql(u8, build_options.platform_backend, "wayland")) {
        @compileError("platform_linux_wayland: backend '" ++ build_options.platform_backend ++
            "' で Wayland 実装が import された（dispatcher は wayland のときだけ選ぶはず）");
    }

    // build 土台確認（AC#3）: 上の @cImport は 3 ヘッダ（wayland-client / xkbcommon / 生成
    // xdg-shell-client-protocol.h）を **同一翻訳単位** で取り込む。名前が安定な公開関数シンボルを
    // 1 つ参照するだけで、翻訳単位全体（= 3 ヘッダ全て）の compile と include path 解決が強制される。
    // 翻訳単位が 1 つなので、xdg-shell 生成 header の include path 不備もここで顕在化する。
    // 実利用（wl_display 接続等）は TASK-28.5.2 以降。struct/typedef 名に依存しない関数参照を使う。
    _ = c.wl_display_connect;
}

// getTime / ファイルダイアログ（display 非依存）は common に分離。X11 と同じく re-export する。
pub const getTime = common.getTime;
pub const saveFileDialog = common.saveFileDialog;
pub const openFileDialog = common.openFileDialog;

pub fn init() Error!void {
    // 実 display 接続は TASK-28.5.2。土台段階では Wayland backend は機能を持たない。
    return error.InitFailed;
}

pub fn shutdown() void {}

/// Locked framebuffer view（公開 contract は canonical BGRA `[]u32`、u32 0xAARRGGBB）。
/// 28.5.2 で wl_shm buffer の pixels を指す。現状は型を満たすだけ。
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn unlock(self: Framebuffer) void {
        _ = self;
    }
};

pub const Window = struct {
    // 土台段階では native handle を持たない（create が常に失敗するため未構築）。
    // wl_display / wl_surface / xdg_toplevel / xkb_state 等の保持は TASK-28.5.2/28.5.3 で State として追加する。

    pub fn create(width: u32, height: u32, title: [:0]const u8) Error!Window {
        _ = width;
        _ = height;
        _ = title;
        // wl_display 接続 / surface / shm buffer は TASK-28.5.2。
        return error.WindowCreationFailed;
    }

    pub fn destroy(self: Window) void {
        _ = self;
    }

    pub fn pollEvents(self: Window) bool {
        _ = self;
        // 公開契約は「false=終了」。create が常に失敗する土台段階では到達しないが、
        // 万一到達してもループに入らない安全側の値を返す。
        return false;
    }

    pub fn nextEvent(self: Window) ?Event {
        _ = self;
        return null;
    }

    pub fn getEventStats(self: Window) EventStats {
        _ = self;
        return .{
            .mouse_move_merge_count = 0,
            .mouse_scroll_merge_count = 0,
            .event_drop_count = 0,
        };
    }

    pub fn lockFramebuffer(self: Window) ?Framebuffer {
        _ = self;
        return null;
    }

    pub fn present(self: Window) void {
        _ = self;
    }
};
