//! Platform 層の共有型定義（backend 非依存の純 Zig 型）
//!
//! macOS / Linux 等の各 backend が参照する「正準の型契約」。C ABI (`platform.h`)
//! には依存しない。各 backend は自身の native 値（C 構造体や Xlib イベント等）から
//! これらの型を構築する。`src/platform.zig`（facade）はこのファイルの型を単一ソースとして
//! 公開し、`Window`/`Framebuffer` と関数群だけを各 backend から re-export する。

const std = @import("std");

pub const Error = error{
    InitFailed,
    WindowCreationFailed,
};

// ============================================================================
// KeyCode (non-exhaustive enum)
// ============================================================================
//
// 物理キーボードの仮想キーコード。non-exhaustive (`_,`) にしているのは:
//   - 未列挙の値が来ても `@enumFromInt` が panic しない
//   - 別バックエンド (Linux/X11 等) が独自キーを足したいときの拡張余地
//
// 値は `platform.h` の PlatformKeyCode と同値（macOS backend が C 値をそのまま流用するため）。

pub const KeyCode = enum(c_int) {
    UNKNOWN = -1,

    SPACE = 32,

    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,

    A = 65,
    B = 66,
    C = 67,
    D = 68,
    E = 69,
    F = 70,
    G = 71,
    H = 72,
    I = 73,
    J = 74,
    K = 75,
    L = 76,
    M = 77,
    N = 78,
    O = 79,
    P = 80,
    Q = 81,
    R = 82,
    S = 83,
    T = 84,
    U = 85,
    V = 86,
    W = 87,
    X = 88,
    Y = 89,
    Z = 90,

    ESCAPE = 256,
    ENTER = 257,
    TAB = 258,
    BACKSPACE = 259,
    INSERT = 260,
    DELETE = 261,
    LEFT = 263,
    RIGHT = 264,
    UP = 265,
    DOWN = 266,
    PAGE_UP = 267,
    PAGE_DOWN = 268,
    HOME = 269,
    END = 270,

    CAPS_LOCK = 280,
    PRINT_SCREEN = 283,
    PAUSE = 284,

    F1 = 290,
    F2 = 291,
    F3 = 292,
    F4 = 293,
    F5 = 294,
    F6 = 295,
    F7 = 296,
    F8 = 297,
    F9 = 298,
    F10 = 299,
    F11 = 300,
    F12 = 301,
    F13 = 302,
    F14 = 303,
    F15 = 304,
    F16 = 305,
    F17 = 306,
    F18 = 307,
    F19 = 308,
    F20 = 309,

    KP_0 = 320,
    KP_1 = 321,
    KP_2 = 322,
    KP_3 = 323,
    KP_4 = 324,
    KP_5 = 325,
    KP_6 = 326,
    KP_7 = 327,
    KP_8 = 328,
    KP_9 = 329,
    KP_DECIMAL = 330,
    KP_DIVIDE = 331,
    KP_MULTIPLY = 332,
    KP_SUBTRACT = 333,
    KP_ADD = 334,
    KP_ENTER = 335,
    KP_EQUAL = 336,

    LEFT_SHIFT = 340,
    LEFT_CONTROL = 341,
    LEFT_ALT = 342,
    LEFT_SUPER = 343,
    RIGHT_SHIFT = 344,
    RIGHT_CONTROL = 345,
    RIGHT_ALT = 346,
    RIGHT_SUPER = 347,

    _,
};

// ============================================================================
// ModifierFlags (packed struct, LSB-first で C の bit-mask と一致)
// ============================================================================

pub const ModifierFlags = packed struct(u32) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    cmd: bool = false,
    _reserved: u28 = 0,

    pub inline fn fromC(raw: u32) ModifierFlags {
        return @bitCast(raw);
    }

    pub inline fn toC(self: ModifierFlags) u32 {
        return @bitCast(self);
    }
};

comptime {
    // C の SHIFT=0x01, CTRL=0x02, ALT=0x04, CMD=0x08 と packed struct のビット並びが一致することを保証
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .shift = true })) == 0x01);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .ctrl = true })) == 0x02);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .alt = true })) == 0x04);
    std.debug.assert(@as(u32, @bitCast(ModifierFlags{ .cmd = true })) == 0x08);
}

// ============================================================================
// MouseButton (物理ボタン基準、C 側 PlatformMouseButton と同じ int 幅)
// ============================================================================

pub const MouseButton = enum(c_int) {
    left = 0,
    right = 1,
    middle = 2,
    none = 0xFF,
    _,
};

// ============================================================================
// MouseButtons (packed struct, LSB-first で C の bit-mask と一致)
// ============================================================================

pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,

    pub inline fn fromC(raw: u8) MouseButtons {
        return @bitCast(raw);
    }

    pub inline fn toC(self: MouseButtons) u8 {
        return @bitCast(self);
    }
};

comptime {
    // C 側 LEFT=0x01, RIGHT=0x02, MIDDLE=0x04 と packed struct のビット並びが一致することを保証
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .left = true })) == 0x01);
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .right = true })) == 0x02);
    std.debug.assert(@as(u8, @bitCast(MouseButtons{ .middle = true })) == 0x04);
}

// ============================================================================
// Event
// ============================================================================

pub const KeyEvent = struct {
    key: KeyCode,
    is_repeat: bool,
    modifiers: ModifierFlags,
};

/// テキスト入力イベント（TASK-22）。key_down（物理キー）と独立した「確定文字」の通知。
/// codepoint は UTF-32（Unicode スカラー値）。IME/変換・marked text は今回スコープ外
/// （英数の確定文字前提。将来 IME は TASK-79.6）。制御文字（0x20 未満・DELETE 0x7f）は
/// backend 側で除外して印字可能文字のみ流す。
pub const CharEvent = struct {
    codepoint: u32,
    modifiers: ModifierFlags,
};

/// マウスイベント。座標は window 座標 (window contentRect 左上原点・logical 単位)。
/// framebuffer / canvas への変換は caller の責任。
pub const MouseEvent = struct {
    x: i32,
    y: i32,
    button: MouseButton, // mouse_move では .none、mouse_down/up でのみ left/right/middle
    buttons: MouseButtons, // 現在押下中のボタン集合 (post-state)
    modifiers: ModifierFlags,
};

/// スクロールイベント。dx, dy の単位は window 座標と同じ。
pub const ScrollEvent = struct {
    x: i32,
    y: i32,
    dx: f32,
    dy: f32,
    is_precise: bool,
    buttons: MouseButtons,
    modifiers: ModifierFlags,
};

pub const Event = union(enum) {
    quit,
    key_down: KeyEvent,
    key_up: KeyEvent,
    char_input: CharEvent, // 確定テキスト文字（TASK-22。key_down と独立）
    mouse_move: MouseEvent,
    mouse_down: MouseEvent,
    mouse_up: MouseEvent,
    mouse_scroll: ScrollEvent,
    gamepad_connected: GamepadInfo, // ゲームパッド接続（TASK-80.1。ADR-009）
    gamepad_disconnected: GamepadDisconnect, // ゲームパッド切断
};

/// イベントキューの観測カウンタ (累積値の snapshot)
pub const EventStats = struct {
    mouse_move_merge_count: u64,
    mouse_scroll_merge_count: u64,
    event_drop_count: u64,
};

// ============================================================================
// ゲームパッド (TASK-80.1。ADR-009)
// ============================================================================
//
// 設計の正は docs/adr/009_ゲームパッド入力.md。ポーリング主軸（Window.getGamepadState）+
// 接続イベント（Event.gamepad_connected/disconnected）。標準レイアウトへ正規化済みの値のみを
// 公開し（native raw レポートは backend 内部に閉じる）、トリガーは axis のみ（ボタンとしては
// 公開しない）。deadzone は未適用の raw 値（stick -1..1 / trigger 0..1）を返し、適用は
// `src/gamepad.zig` の `applyDeadzone()` へ委ねる。
//
// 呼び出し頻度: `GamepadState` はフレーム毎にポーリングされる想定だが、4台×少数フィールドの
// 固定長 copy（alloc/lock 無し）で全画素ループでも RT でもないため性能規約
// （SIMD 3点セット・cache_line 分離等）の適用対象外（ADR-009「ホットパス宣言」節）。

/// 同時サポートするゲームパッド数（`Window.getGamepadState`/harness の `gamepad_states` 配列長の
/// 単一ソース）。
pub const MAX_GAMEPADS: u8 = 4;

/// 標準レイアウトのボタン（15 種。exhaustive enum。ADR-009 決定）。
/// 固定レイアウトのため拡張は「末尾に値を追加」で足りる。non-exhaustive にすると
/// isSet/set/getButtonName/harness parser 全箇所に未知値分岐が要るため見送った。
pub const GamepadButton = enum(u8) {
    a,
    b,
    x,
    y,
    left_shoulder,
    right_shoulder,
    back,
    start,
    left_stick, // スティック押し込み（クリック）
    right_stick,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    guide, // Xbox ボタン相当（ホームボタン）
};

// ============================================================================
// GamepadButtons (packed struct, LSB-first で C の PlatformGamepadButtonFlags と一致)
// ============================================================================

pub const GamepadButtons = packed struct(u32) {
    a: bool = false,
    b: bool = false,
    x: bool = false,
    y: bool = false,
    left_shoulder: bool = false,
    right_shoulder: bool = false,
    back: bool = false,
    start: bool = false,
    left_stick: bool = false,
    right_stick: bool = false,
    dpad_up: bool = false,
    dpad_down: bool = false,
    dpad_left: bool = false,
    dpad_right: bool = false,
    guide: bool = false,
    _reserved: u17 = 0,

    pub inline fn fromC(raw: u32) GamepadButtons {
        return @bitCast(raw);
    }

    pub inline fn toC(self: GamepadButtons) u32 {
        return @bitCast(self);
    }

    pub fn isSet(self: GamepadButtons, btn: GamepadButton) bool {
        return switch (btn) {
            .a => self.a,
            .b => self.b,
            .x => self.x,
            .y => self.y,
            .left_shoulder => self.left_shoulder,
            .right_shoulder => self.right_shoulder,
            .back => self.back,
            .start => self.start,
            .left_stick => self.left_stick,
            .right_stick => self.right_stick,
            .dpad_up => self.dpad_up,
            .dpad_down => self.dpad_down,
            .dpad_left => self.dpad_left,
            .dpad_right => self.dpad_right,
            .guide => self.guide,
        };
    }

    pub fn set(self: *GamepadButtons, btn: GamepadButton, value: bool) void {
        switch (btn) {
            .a => self.a = value,
            .b => self.b = value,
            .x => self.x = value,
            .y => self.y = value,
            .left_shoulder => self.left_shoulder = value,
            .right_shoulder => self.right_shoulder = value,
            .back => self.back = value,
            .start => self.start = value,
            .left_stick => self.left_stick = value,
            .right_stick => self.right_stick = value,
            .dpad_up => self.dpad_up = value,
            .dpad_down => self.dpad_down = value,
            .dpad_left => self.dpad_left = value,
            .dpad_right => self.dpad_right = value,
            .guide => self.guide = value,
        }
    }
};

comptime {
    // C 側 PlatformGamepadButtonFlags の bit 位置（a=bit0 … guide=bit14）と一致することを保証
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .a = true })) == 0x0001);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .b = true })) == 0x0002);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .x = true })) == 0x0004);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .y = true })) == 0x0008);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .left_shoulder = true })) == 0x0010);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .right_shoulder = true })) == 0x0020);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .back = true })) == 0x0040);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .start = true })) == 0x0080);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .left_stick = true })) == 0x0100);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .right_stick = true })) == 0x0200);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_up = true })) == 0x0400);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_down = true })) == 0x0800);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_left = true })) == 0x1000);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .dpad_right = true })) == 0x2000);
    std.debug.assert(@as(u32, @bitCast(GamepadButtons{ .guide = true })) == 0x4000);
}

/// アナログスティック（raw値。-1.0..1.0。deadzone 未適用。ADR-009）。
pub const Stick = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// ゲームパッドの正規化済みポーリング状態（`Window.getGamepadState` の戻り値）。
pub const GamepadState = struct {
    buttons: GamepadButtons = .{},
    left_stick: Stick = .{},
    right_stick: Stick = .{},
    left_trigger: f32 = 0, // raw値。0.0..1.0
    right_trigger: f32 = 0, // raw値。0.0..1.0
};

/// `GamepadInfo.name` の最大バイト数（UTF-8 バイト列。NUL 不要 = name_len で管理）。
pub const GAMEPAD_NAME_MAX: usize = 32;

/// ゲームパッド接続イベントのペイロード。`name` は `name_len` バイトのみ有効
/// （固定長 buffer + 使用長。allocator 不要で Event union に値として載せられる）。
pub const GamepadInfo = struct {
    index: u8,
    name_len: u8 = 0,
    name_buf: [GAMEPAD_NAME_MAX]u8 = [_]u8{0} ** GAMEPAD_NAME_MAX,

    pub fn name(self: *const GamepadInfo) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// ゲームパッド切断イベントのペイロード。
pub const GamepadDisconnect = struct {
    index: u8,
};

// ============================================================================
// ファイル選択ダイアログ (TASK-24 / Linux: TASK-28.4)
// ============================================================================

/// ファイルダイアログのエラー（全 OS 共通の戻り値型に使う）。
/// - DialogUnavailable: ダイアログ機構が使えない（Linux: zenity 不在）。
///   macOS/Windows は通常返さない（型互換のため宣言に含める）。
/// - DialogFailed: 予期せぬ失敗（異常終了 / signal / 環境不備等）。
/// - DialogPending: 非同期ダイアログが進行中（wasm file picker。次 frame で再試行。TASK-73.3）。
///   native backend は返さない（型互換のため宣言に含める）。
/// ユーザーキャンセルは error ではなく null で表す。OOM は Allocator.Error。
pub const DialogError = error{ DialogUnavailable, DialogFailed, DialogPending };

pub const SaveDialogOptions = struct {
    default_name: ?[:0]const u8 = null,
    allowed_ext: ?[:0]const u8 = null,
};

pub const OpenDialogOptions = struct {
    allowed_ext: ?[:0]const u8 = null,
};

// ============================================================================
// CursorShape (システムカーソル。TASK-75.1)
// ============================================================================
//
// M1 スコープは 3 値のみ（TASK-75 の設計でツール識別はソフトオーバーレイに委ね、OS ハードカーソルは
// precision point 用に crosshair/default/hidden の 3 種だけを使うと確定済み）。値は `platform.h` の
// PlatformCursorShape と同値（macOS backend が C 値をそのまま流用するため）。
//
// 呼び出し頻度: ツール切替・キー入力等の**イベント時のみ**。フレーム毎の全画素ループでも RT（毎サンプル）
// 経路でもないため、性能規約（SIMD 3点セット・cache_line 分離等）の適用対象外。
pub const CursorShape = enum(c_int) {
    default = 0,
    crosshair = 1,
    hidden = 2,
};

test "ModifierFlags round trip via @bitCast" {
    const m = ModifierFlags{ .shift = true, .cmd = true };
    const raw = m.toC();
    try std.testing.expectEqual(@as(u32, 0x09), raw);
    const back = ModifierFlags.fromC(raw);
    try std.testing.expect(back.shift);
    try std.testing.expect(!back.ctrl);
    try std.testing.expect(!back.alt);
    try std.testing.expect(back.cmd);
}

test "GamepadButtons: isSet/set は全15ボタンで独立に効き、他ビットを汚さない" {
    var b = GamepadButtons{};
    inline for (@typeInfo(GamepadButton).@"enum".fields) |f| {
        const btn: GamepadButton = @enumFromInt(f.value);
        try std.testing.expect(!b.isSet(btn));
    }
    b.set(.a, true);
    b.set(.start, true);
    try std.testing.expect(b.isSet(.a));
    try std.testing.expect(b.isSet(.start));
    try std.testing.expect(!b.isSet(.b));
    try std.testing.expect(!b.isSet(.guide));
    b.set(.a, false);
    try std.testing.expect(!b.isSet(.a));
    try std.testing.expect(b.isSet(.start)); // 他ビットは無変更
}

test "GamepadButtons round trip via @bitCast (toC/fromC)" {
    var b = GamepadButtons{};
    b.set(.a, true);
    b.set(.guide, true);
    const raw = b.toC();
    try std.testing.expectEqual(@as(u32, 0x0001 | 0x4000), raw);
    const back = GamepadButtons.fromC(raw);
    try std.testing.expect(back.isSet(.a));
    try std.testing.expect(back.isSet(.guide));
    try std.testing.expect(!back.isSet(.b));
}

test "GamepadInfo.name: name_len が指す範囲だけを返す" {
    var info = GamepadInfo{ .index = 0 };
    const src = "Pad";
    @memcpy(info.name_buf[0..src.len], src);
    info.name_len = src.len;
    try std.testing.expectEqualStrings("Pad", info.name());
}
