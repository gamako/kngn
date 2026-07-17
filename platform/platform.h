#ifndef PLATFORM_H
#define PLATFORM_H

#include <stdint.h>
#include <stdbool.h>

// プラットフォーム抽象化レイヤー
// Windows, Linux, macOSで共通のインターフェース

// 不透明なウィンドウハンドル型
typedef struct PlatformWindow PlatformWindow;

// フレームバッファのコールバック関数型
// ユーザーコードが毎フレーム呼ばれ、ピクセルデータを更新する
// pixels: canonical BGRA 形式の32bitピクセル配列 (u32 0xAARRGGBB / メモリ [B,G,R,A], width * height)
// width, height: フレームバッファのサイズ
// userdata: プラットフォーム初期化時に渡したユーザーデータ
typedef void (*FrameCallback)(uint32_t* pixels, int width, int height, void* userdata);

// プラットフォームの初期化
// 成功時はtrue、失敗時はfalseを返す
bool platform_init(void);

// ウィンドウを作成
// width, height: ウィンドウサイズ (ピクセル)
// title: ウィンドウタイトル
// callback: 毎フレーム呼ばれる描画コールバック関数
// userdata: コールバックに渡されるユーザーデータ
// 戻り値: ウィンドウハンドル（失敗時はNULL）
PlatformWindow* platform_create_window(int width, int height, const char* title,
                                       FrameCallback callback, void* userdata);

// 既存ウィンドウを本物のフルスクリーンにする（TASK-100.1）。
// facade の Window.createFullscreen が create 後に呼ぶ。macOS は NSWindow の
// toggleFullScreen:（緑ボタンと同じネイティブフルスクリーン。既にフルスクリーンなら no-op）。
void platform_enter_fullscreen(PlatformWindow* window);

// ========================================
// 透過 / borderless ウィンドウ + 対話的ドラッグ移動 (TASK-104)
// ========================================
//
// デスクトップマスコット等の「背後が透けて枠の無い浮遊ウィンドウ」を作るための拡張。
// 透過は fb の alpha を honor する（透過時のみ premultiplied alpha 前提。不透明時は従来どおり
// alpha 無視）。ドラッグ移動は OS の対話的ウィンドウ移動へ委譲する（Wayland のように
// クライアントが絶対位置を設定できない環境でも成立させるため。macOS は
// performWindowDragWithEvent:）。詳細設計は docs/plans/transparent-window-plan.md。

// ウィンドウ生成オプション（bit flags）。opts==NULL は既定（不透明・タイトル付き）と同義。
// x/y は PLATFORM_WINDOW_POSITION が立っているときだけ参照する（未設定時は center 等の従来配置）。
typedef struct PlatformWindowOptions {
    uint32_t flags;     // PLATFORM_WINDOW_* の OR
    uint32_t reserved;  // 将来拡張用（0 埋め。非 0 は NULL）
    int32_t x;          // OS 画面座標（TASK-117）
    int32_t y;
} PlatformWindowOptions;

#define PLATFORM_WINDOW_TRANSPARENT (1u << 0)  // fb の alpha を honor（背後が透ける）
#define PLATFORM_WINDOW_BORDERLESS  (1u << 1)  // タイトルバー・枠なし（borderless）
#define PLATFORM_WINDOW_POSITION    (1u << 2)  // x/y を初期位置として適用（TASK-117）

// 現在のウィンドウ geometry（TASK-117）。サイズは content/client、位置は OS 画面座標。
// flags に PLATFORM_GEOMETRY_POSITION_VALID が無いとき x/y は未定義（位置非対応/取得不能）。
typedef struct PlatformWindowGeometry {
    int32_t x;
    int32_t y;
    uint32_t width;
    uint32_t height;
    uint32_t flags; // PLATFORM_GEOMETRY_* の OR
} PlatformWindowGeometry;

#define PLATFORM_GEOMETRY_POSITION_VALID (1u << 0)

// options 付きでウィンドウを作成する（既存 platform_create_window の拡張版）。
// opts==NULL は既定動作（platform_create_window と同義）。unknown flags / reserved!=0 は
// NULL を返す（silent 無視しない。facade 側で error.Unsupported に変換される）。
// 関数シグネチャは不変。位置指定は PLATFORM_WINDOW_POSITION が立っている場合だけ参照する。
PlatformWindow* platform_create_window_ex(int width, int height, const char* title,
                                          FrameCallback callback, void* userdata,
                                          const PlatformWindowOptions* opts);

// 現在のウィンドウ geometry を取得する（TASK-117）。window/out が NULL なら no-op。
// 失敗時も out をゼロ埋めし、クラッシュしない（position は VALID 無し）。
void platform_get_window_geometry(PlatformWindow* window, PlatformWindowGeometry* out);

// 表示中のウィンドウタイトルを更新する（イベント時のみ）。
void platform_set_title(PlatformWindow* window, const char* title);

// 直近のポインタ押下から OS の対話的ウィンドウ移動を開始する（実移動は OS 側）。
// アプリは「掴む領域で mouse_down を受けたら」これを呼ぶ。macOS は保持した直近の左ボタン
// mouse-down NSEvent を performWindowDragWithEvent: に渡し、呼び出し時に保持 event をクリアする
// （one-shot。保持 event が無ければ no-op）。呼び出し頻度: mouse_down 起点のイベント時のみ。
void platform_begin_window_drag(PlatformWindow* window);

// 常に最前面（always-on-top）を設定する。macOS は NSWindow.level を切替える。イベント時のみ。
void platform_set_always_on_top(PlatformWindow* window, bool on);

// クリック透過（per-pixel）を設定する。ON のとき、直近表示フレームの alpha==0 の画素上の
// クリックは背後のアプリへ抜け、alpha>0（不透明な絵の本体）上のクリックだけが window に届く。
// マスコット本体をドラッグしつつ透明な余白はデスクトップへ抜けさせるための機能。イベント時のみ。
void platform_set_click_through(PlatformWindow* window, bool on);

// Dock アイコン / メニューバーの表示を切替える（アプリ全体。window 非依存）。
// visible=false で NSApplicationActivationPolicyAccessory（常駐アプリらしくする）。
void platform_set_dock_visible(bool visible);

// 終了メニューをポップアップする（右クリック等から。1 項目「終了」の native メニュー）。
// 「終了」が選ばれたら window のイベントキューに QUIT を積む（モーダル。選択なしは何もしない）。
void platform_show_quit_menu(PlatformWindow* window);

// メインイベントループを開始（ブロッキング）
// ウィンドウが閉じられるまで戻らない
void platform_run(PlatformWindow* window);

// ウィンドウを破棄
void platform_destroy_window(PlatformWindow* window);

// プラットフォームのクリーンアップ
void platform_shutdown(void);

// ========================================
// 手動描画用API（コールバック方式と共存可能）
// ========================================

// イベントをポーリング（ノンブロッキング）
// ウィンドウが閉じられていなければtrue、閉じられたらfalseを返す
// この関数を呼び出すことで、OSのイベントが処理される
bool platform_poll_events(PlatformWindow* window);

// 高精度モノトニック時刻を取得（秒単位、double型）
//
// 特性:
// - モノトニック: 時刻は単調増加し、決して逆戻りしない
// - 調整なし（RAW）: NTP等のシステム時刻調整の影響を受けない
// - 高精度: マイクロ秒以下の精度（プラットフォーム依存）
//   * Windows: ~100ns (QueryPerformanceCounter)
//   * macOS: ~1ns (CLOCK_UPTIME_RAW)
//   * Linux: ~1ns (CLOCK_MONOTONIC_RAW)
//
// 戻り値:
// - システム起動またはプロセス開始からの経過時間（秒）
// - 絶対値は意味を持たない（時刻差分の計算にのみ使用）
//
// 用途:
// - フレーム間隔の計測: dt = current_time - last_time
// - アニメーション制御
// - ベンチマーク、プロファイリング
//
// 注意:
// - この時刻はシステムの壁時計（wall clock）とは無関係
// - ネットワーク同期が必要な場合は別途サーバー時刻管理が必要
// - 長時間実行時、システム時刻とのずれが蓄積する可能性がある
double platform_get_time(void);

// フレームバッファへのアクセスを開始
// out_width, out_height: フレームバッファのサイズが返される
// 戻り値: ピクセルバッファへのポインタ（canonical BGRA, u32 0xAARRGGBB, 32bit）
//   - NULL は「今は描画可能な frame slot が無い」retry 可能状態を表しうる（frame slot unavailable）。
//     caller はそのフレームの描画を skip し、pollEvents 等を回して次の機会を待てる
//     （macOS backend は現状 NULL を返さないが、Wayland 等の 1級 backend は frame callback / busy buffer 律速で NULL を返す）。
//   - device lost / window 破棄などの fatal は NULL とは別経路で扱う方針（詳細は docs/adr/005）。
// 注意: platform_unlock_framebuffer()を呼ぶまでバッファを保持
uint32_t* platform_lock_framebuffer(PlatformWindow* window, int* out_width, int* out_height);

// フレームバッファへのアクセスを終了
// platform_lock_framebuffer()とペアで使用
void platform_unlock_framebuffer(PlatformWindow* window);

// ========================================
// カーソル制御API (TASK-75.1)
// ========================================

// システムカーソルの形状。M1 スコープは 3 種のみ
// （TASK-75 の設計でツール識別はソフトオーバーレイに委ね、OS ハードカーソルは
//  precision point 用に crosshair/default/hidden の 3 種だけを使うと確定済み）。
typedef enum {
    PLATFORM_CURSOR_DEFAULT = 0,   // 標準の矢印
    PLATFORM_CURSOR_CROSSHAIR = 1, // 十字（キャンバス等の精密操作向け）
    PLATFORM_CURSOR_HIDDEN = 2,    // 非表示（ソフトオーバーレイ描画時などに使用）
} PlatformCursorShape;

// カーソル形状を設定する。
// 呼び出し頻度: ツール切替・キー入力等のイベント時のみを想定（毎フレーム呼ばない）。
// shape は PlatformCursorShape の値（enum 型でなく int で受ける。実装は platform_set_cursor 参照）。
// 未知の値は PLATFORM_CURSOR_DEFAULT にフォールバックする。
// backend 対応状況: macOS は NSCursor へ即時反映。Linux/Windows は現状 no-op（TASK-75.2/75.3 で実装予定）。
void platform_set_cursor(PlatformWindow* window, int shape);

// ========================================
// ライブリサイズ再描画コールバック (TASK-23.1)
// ========================================
//
// OS のモーダル/ネストした event-tracking ループ（枠ドラッグ中）から、app へ
// 「今 1 フレーム描いてほしい」とだけ通知する opt-in 機構。pixels は渡さない
// （app が普段どおり lockFramebuffer → draw → present を回す）。
// cb == NULL で登録解除。単一ウィンドウ前提。

typedef void (*PlatformRedrawCallback)(void* userdata);
void platform_set_redraw_callback(PlatformWindow* window, PlatformRedrawCallback cb, void* userdata);

// 画面を更新（present = 直近 lock したフレームを表示キューへ submit する）
// platform_lock_framebuffer()で書き込んだ内容を表示キューへ送る
//
// 動作:
// - この関数は基本的に非ブロックの submit（display refresh までは待たない）。ただし resource pressure や
//   inflight 枠の都合で短時間 block する可能性は許容する（下記 Metal を参照）
// - frame 確定点として扱う（TASK-32 harness はこの時点で frame を確定する）
// - present 後の pixels は backend / WindowServer / GPU 所有となり、caller は次の lock まで触らない
//
// frame pacing / tearing（backend の support tier に依る・TASK-34）:
// - 1級 backend（Metal / D3D11-DXGI / Wayland）は fifo で display refresh に同期し tearing 回避を保証対象とする
//   * Metal は inflight 上限（triple slot + semaphore, TASK-36）に達すると、submit が次フレーム枠の空きまで
//     短時間 block しうる（= fifo pacing。display refresh 律速）。lockFramebuffer は non-null 互換を維持する
// - best-effort backend（macOS CALayer objc/swift / X11 / GDI）は厳密な vsync / tearing 回避を保証しない
//
// 注意:
// - ゲームループのレート制御は呼び出し側の責任（platform_get_time()とsleep()、または将来の beginFrame/waitFrame）
// - present / lockFramebuffer / frame pacing 契約の正は docs/adr/002（改訂）と docs/adr/005
void platform_present(PlatformWindow* window);

// ========================================
// イベント処理API
// ========================================

// イベントタイプ
typedef enum {
    PLATFORM_EVENT_NONE = 0,
    PLATFORM_EVENT_QUIT,
    PLATFORM_EVENT_KEY_DOWN,
    PLATFORM_EVENT_KEY_UP,
    PLATFORM_EVENT_MOUSE_MOVE,
    PLATFORM_EVENT_MOUSE_DOWN,
    PLATFORM_EVENT_MOUSE_UP,
    PLATFORM_EVENT_MOUSE_SCROLL,
    PLATFORM_EVENT_CHAR_INPUT,   // 確定テキスト文字 (TASK-22。末尾追加=後方互換)
    PLATFORM_EVENT_GAMEPAD_CONNECTED,    // ゲームパッド接続 (TASK-80.1。実消費は TASK-80.2。末尾追加=後方互換)
    PLATFORM_EVENT_GAMEPAD_DISCONNECTED, // ゲームパッド切断
    PLATFORM_EVENT_COMPOSITION,  // IME composition 状態変化 (TASK-79.6.1。末尾追加=後方互換)
    PLATFORM_EVENT_MENU_COMMAND, // native メニュー選択 (TASK-97.3。末尾追加=後方互換。payload=数値 Command ID)
} PlatformEventType;

// IME composition phase（TASK-79.6.1。Zig CompositionPhase と値一致）
typedef enum {
    PLATFORM_COMPOSITION_PHASE_START = 0,
    PLATFORM_COMPOSITION_PHASE_UPDATE = 1,
    PLATFORM_COMPOSITION_PHASE_COMMIT = 2,
    PLATFORM_COMPOSITION_PHASE_CANCEL = 3,
} PlatformCompositionPhase;

// マウスボタン (物理ボタン基準: NSEvent.buttonNumber と一致)
// C enum はストレージ型未指定 = int 幅。Zig 側は enum(c_int) で受ける。
typedef enum {
    PLATFORM_MOUSE_BUTTON_NONE = 0xFF,    // MOUSE_MOVE で button フィールドが意味を持たない時
    PLATFORM_MOUSE_BUTTON_LEFT = 0,
    PLATFORM_MOUSE_BUTTON_RIGHT = 1,
    PLATFORM_MOUSE_BUTTON_MIDDLE = 2,
} PlatformMouseButton;

// PlatformMouseButton の bit-mask 版 (LSB-first: 0x01=left, 0x02=right, 0x04=middle)
typedef enum {
    PLATFORM_MOUSE_BUTTON_FLAG_LEFT   = 0x01,
    PLATFORM_MOUSE_BUTTON_FLAG_RIGHT  = 0x02,
    PLATFORM_MOUSE_BUTTON_FLAG_MIDDLE = 0x04,
} PlatformMouseButtonFlags;

// キーコード
// 物理キーボードの位置に基づいた仮想キーコード
typedef enum {
    PLATFORM_KEY_UNKNOWN = -1,

    // 印字可能文字（ASCII互換）
    PLATFORM_KEY_SPACE = 32,
    PLATFORM_KEY_0 = 48,
    PLATFORM_KEY_1 = 49,
    PLATFORM_KEY_2 = 50,
    PLATFORM_KEY_3 = 51,
    PLATFORM_KEY_4 = 52,
    PLATFORM_KEY_5 = 53,
    PLATFORM_KEY_6 = 54,
    PLATFORM_KEY_7 = 55,
    PLATFORM_KEY_8 = 56,
    PLATFORM_KEY_9 = 57,
    PLATFORM_KEY_A = 65,
    PLATFORM_KEY_B = 66,
    PLATFORM_KEY_C = 67,
    PLATFORM_KEY_D = 68,
    PLATFORM_KEY_E = 69,
    PLATFORM_KEY_F = 70,
    PLATFORM_KEY_G = 71,
    PLATFORM_KEY_H = 72,
    PLATFORM_KEY_I = 73,
    PLATFORM_KEY_J = 74,
    PLATFORM_KEY_K = 75,
    PLATFORM_KEY_L = 76,
    PLATFORM_KEY_M = 77,
    PLATFORM_KEY_N = 78,
    PLATFORM_KEY_O = 79,
    PLATFORM_KEY_P = 80,
    PLATFORM_KEY_Q = 81,
    PLATFORM_KEY_R = 82,
    PLATFORM_KEY_S = 83,
    PLATFORM_KEY_T = 84,
    PLATFORM_KEY_U = 85,
    PLATFORM_KEY_V = 86,
    PLATFORM_KEY_W = 87,
    PLATFORM_KEY_X = 88,
    PLATFORM_KEY_Y = 89,
    PLATFORM_KEY_Z = 90,

    // 編集キー
    PLATFORM_KEY_TAB = 258,
    PLATFORM_KEY_BACKSPACE = 259,
    PLATFORM_KEY_INSERT = 260,
    PLATFORM_KEY_DELETE = 261,
    PLATFORM_KEY_PAGE_UP = 267,
    PLATFORM_KEY_PAGE_DOWN = 268,
    PLATFORM_KEY_HOME = 269,
    PLATFORM_KEY_END = 270,

    // 特殊キー
    PLATFORM_KEY_ESCAPE = 256,
    PLATFORM_KEY_ENTER = 257,
    PLATFORM_KEY_LEFT = 263,
    PLATFORM_KEY_RIGHT = 264,
    PLATFORM_KEY_UP = 265,
    PLATFORM_KEY_DOWN = 266,

    // ファンクションキー（F1-F20）
    PLATFORM_KEY_F1 = 290,
    PLATFORM_KEY_F2 = 291,
    PLATFORM_KEY_F3 = 292,
    PLATFORM_KEY_F4 = 293,
    PLATFORM_KEY_F5 = 294,
    PLATFORM_KEY_F6 = 295,
    PLATFORM_KEY_F7 = 296,
    PLATFORM_KEY_F8 = 297,
    PLATFORM_KEY_F9 = 298,
    PLATFORM_KEY_F10 = 299,
    PLATFORM_KEY_F11 = 300,
    PLATFORM_KEY_F12 = 301,
    PLATFORM_KEY_F13 = 302,
    PLATFORM_KEY_F14 = 303,
    PLATFORM_KEY_F15 = 304,
    PLATFORM_KEY_F16 = 305,
    PLATFORM_KEY_F17 = 306,
    PLATFORM_KEY_F18 = 307,
    PLATFORM_KEY_F19 = 308,
    PLATFORM_KEY_F20 = 309,

    // テンキー（numeric keypad）
    PLATFORM_KEY_KP_0 = 320,
    PLATFORM_KEY_KP_1 = 321,
    PLATFORM_KEY_KP_2 = 322,
    PLATFORM_KEY_KP_3 = 323,
    PLATFORM_KEY_KP_4 = 324,
    PLATFORM_KEY_KP_5 = 325,
    PLATFORM_KEY_KP_6 = 326,
    PLATFORM_KEY_KP_7 = 327,
    PLATFORM_KEY_KP_8 = 328,
    PLATFORM_KEY_KP_9 = 329,
    PLATFORM_KEY_KP_DECIMAL = 330,
    PLATFORM_KEY_KP_DIVIDE = 331,
    PLATFORM_KEY_KP_MULTIPLY = 332,
    PLATFORM_KEY_KP_SUBTRACT = 333,
    PLATFORM_KEY_KP_ADD = 334,
    PLATFORM_KEY_KP_ENTER = 335,
    PLATFORM_KEY_KP_EQUAL = 336,

    // モディファイアキー（単独入力用）
    PLATFORM_KEY_LEFT_SHIFT = 340,
    PLATFORM_KEY_LEFT_CONTROL = 341,
    PLATFORM_KEY_LEFT_ALT = 342,
    PLATFORM_KEY_LEFT_SUPER = 343,        // Command (macOS) / Windows key
    PLATFORM_KEY_RIGHT_SHIFT = 344,
    PLATFORM_KEY_RIGHT_CONTROL = 345,
    PLATFORM_KEY_RIGHT_ALT = 346,
    PLATFORM_KEY_RIGHT_SUPER = 347,       // Command (macOS) / Windows key

    // その他のキー
    PLATFORM_KEY_CAPS_LOCK = 280,
    PLATFORM_KEY_PRINT_SCREEN = 283,
    PLATFORM_KEY_PAUSE = 284,
} PlatformKeyCode;

// モディファイアキー
typedef enum {
    PLATFORM_MOD_SHIFT = 0x01,
    PLATFORM_MOD_CTRL = 0x02,
    PLATFORM_MOD_ALT = 0x04,
    PLATFORM_MOD_CMD = 0x08,  // macOS Command, Windows Super
} PlatformModifierFlags;

// イベント構造体
typedef struct PlatformEvent {
    PlatformEventType type;

    union {
        struct {
            PlatformKeyCode key;
            bool is_repeat;
            uint32_t modifiers;
        } keyboard;
        struct {
            // x, y: window contentRect 左上原点・window logical 単位 (view.bounds と同単位)
            // floor 整数化済み。framebuffer/canvas 変換は caller 責任。
            // ボタン押下中はウィンドウ外でも座標を clamp せず負値もそのまま渡す。
            int32_t x, y;
            PlatformMouseButton button;   // MOUSE_DOWN / MOUSE_UP のみ valid、MOUSE_MOVE では PLATFORM_MOUSE_BUTTON_NONE
            uint8_t buttons_mask;         // 現在押されているボタンの bitmask (post-state, & 0x07 でマスク済み)
            uint32_t modifiers;
        } mouse;
        struct {
            int32_t x, y;                 // window 座標 (mouse と同じ単位)
            float dx, dy;                 // 単位は window 座標と同じ (line 単位の場合は scrollerLineHeight 倍済み)
            bool is_precise;              // true: トラックパッド (連続値), false: ホイール (line→window-units 変換済み)
            uint8_t buttons_mask;         // post-state
            uint32_t modifiers;
        } scroll;
        struct {
            uint32_t codepoint;           // 確定文字の Unicode スカラー値 (UTF-32)。TASK-22
            uint32_t modifiers;
        } character;
        struct {
            int32_t index;                // PLATFORM_MAX_GAMEPADS 範囲の pad index
            char name[33];                 // NUL 終端デバイス名 (32 bytes + NUL。32超は切り詰め)。
                                            // CONNECTED のみ有効、DISCONNECTED は空文字。TASK-80.1
        } gamepad;
        struct {
            uint32_t revision;            // snapshot 突合用。setMarkedText/unmark/insert 毎に増分
            uint8_t phase;                // PlatformCompositionPhase
            uint32_t cursor;              // preedit 内 UTF-8 バイトオフセット（caret）
        } composition;                    // TASK-79.6.1。本文は platform_get_composition_snapshot
        struct {
            uint32_t command_id;          // app の CommandId（数値）。TASK-97.3
        } menu;
    } payload;
} PlatformEvent;

// IME composition snapshot のメタ（本文は caller の buf へ UTF-8 で書く。TASK-79.6.1）
typedef struct PlatformCompositionMeta {
    uint32_t revision;
    uint32_t cursor;   // preedit 内 UTF-8 バイトオフセット
    uint32_t len;      // buf に書いたバイト数（cap で切り詰め済み。NUL 非付与）
} PlatformCompositionMeta;

// 現在の preedit 本文を buf に書く。戻り値 = 書いたバイト数（0 = 空/未 composition）。
// meta は常に埋める（空時は revision/cursor/len = 0）。非 macOS / 未対応 backend は常に 0。
// cap==0 または buf==NULL でも meta は埋める（本文は書かない）。
uint32_t platform_get_composition_snapshot(PlatformWindow* window, char* buf, uint32_t cap, PlatformCompositionMeta* meta);

// IME 候補窓の基準 caret rect を設定する。座標は framebuffer pixel・window content 左上原点。
// backend は firstRectForCharacterRange の問い合わせ時に backing scale を適用する。
void platform_set_composition_rect(PlatformWindow* window, int32_t x, int32_t y, int32_t w, int32_t h);

// イベント取得API（1つずつ）
// ウィンドウのイベントキューから1つイベントを取得する
// イベントがあればtrue、ないならfalseを返す
bool platform_get_event(PlatformWindow* window, PlatformEvent* event);

// イベントキューの観測カウンタ (累積値、snapshot 取得)
// example での合体動作・溢れ検知に使う。
typedef struct PlatformEventStats {
    uint64_t mouse_move_merge_count;    // mouse_move を末尾合体した累積回数
    uint64_t mouse_scroll_merge_count;  // mouse_scroll を末尾合体した累積回数
    uint64_t event_drop_count;          // キュー満杯で捨てた累積回数
} PlatformEventStats;

// イベントキューのカウンタ snapshot を取得
void platform_get_event_stats(PlatformWindow* window, PlatformEventStats* out);

// ========================================
// ゲームパッド入力 (TASK-80.1。ADR-009。実消費は TASK-80.2)
// ========================================
//
// 設計の正は core/platform_types.zig 側の GamepadButton/GamepadButtons/GamepadState と
// docs/adr/009_ゲームパッド入力.md。button の bit 位置は下記 enum の宣言順（a=bit0 … guide=bit14）と
// Zig 側 GamepadButtons のフィールド順を一致させる。トリガーは axis のみで公開する（ボタンとしては
// 公開しない）。stick/trigger は raw 値（deadzone 未適用）。
//
// 本タスク（80.1）はこの型・プロトタイプの宣言のみを確定する。呼び出しコードは存在しないため、
// macOS の .m/.swift 実装ファイルへの変更は不要（未使用の extern 宣言は link 要求を発生させない）。

// PlatformGamepadState.buttons_mask の bit-mask 版
typedef enum {
    PLATFORM_GAMEPAD_BUTTON_A = 0x0001,
    PLATFORM_GAMEPAD_BUTTON_B = 0x0002,
    PLATFORM_GAMEPAD_BUTTON_X = 0x0004,
    PLATFORM_GAMEPAD_BUTTON_Y = 0x0008,
    PLATFORM_GAMEPAD_BUTTON_LEFT_SHOULDER = 0x0010,
    PLATFORM_GAMEPAD_BUTTON_RIGHT_SHOULDER = 0x0020,
    PLATFORM_GAMEPAD_BUTTON_BACK = 0x0040,
    PLATFORM_GAMEPAD_BUTTON_START = 0x0080,
    PLATFORM_GAMEPAD_BUTTON_LEFT_STICK = 0x0100,   // スティック押し込み（クリック）
    PLATFORM_GAMEPAD_BUTTON_RIGHT_STICK = 0x0200,
    PLATFORM_GAMEPAD_BUTTON_DPAD_UP = 0x0400,
    PLATFORM_GAMEPAD_BUTTON_DPAD_DOWN = 0x0800,
    PLATFORM_GAMEPAD_BUTTON_DPAD_LEFT = 0x1000,
    PLATFORM_GAMEPAD_BUTTON_DPAD_RIGHT = 0x2000,
    PLATFORM_GAMEPAD_BUTTON_GUIDE = 0x4000,        // Xbox ボタン相当（ホームボタン）
} PlatformGamepadButtonFlags;

// 同時サポートするゲームパッド数
#define PLATFORM_MAX_GAMEPADS 4

// ゲームパッドの正規化済みポーリング状態
typedef struct PlatformGamepadState {
    uint32_t buttons_mask;              // PlatformGamepadButtonFlags の bit-or
    float left_stick_x, left_stick_y;   // -1.0..1.0（raw値。deadzone 未適用）
    float right_stick_x, right_stick_y; // -1.0..1.0
    float left_trigger, right_trigger;  // 0.0..1.0（raw値。トリガーは axis のみで公開）
} PlatformGamepadState;

// 指定 index のゲームパッド状態を取得する（ポーリング。実装は TASK-80.2）。
// 戻り値: 接続されていれば true（out_state 書込み済み）、未接続/index範囲外は false。
bool platform_get_gamepad_state(PlatformWindow* window, int index, PlatformGamepadState* out_state);

// ========================================
// native メニュー (TASK-97.3。ADR 契約は core/command_types.zig の Command)
// ========================================
//
// C ABI 契約:
// - 登録は PlatformMenuItem 配列 + count 明示（sentinel 終端は使わない）。
// - 文字列は UTF-8 NUL 終端で**呼び出し中のみ有効**（backend が copy する）。
// - 階層は MVP ではトップメニュー 1 段 + 項目のみ（submenu なし。separator は kind で表現）。
// - メニューバーはアプリ単位のため window 引数は無視し、最後の登録が全体を差し替える。
// - 実装は macOS objc/swift/metal backend。`#if defined(VP_ENABLE_MENU)` 条件コンパイル
//   （TASK-80.2 gamepad opt-in と同型。共有 TU は platform_macos_menu.m。TASK-122）。
//   非使用 exe はメニューシンボル参照ゼロ。

#define PLATFORM_MENU_KIND_NORMAL    0
#define PLATFORM_MENU_KIND_SEPARATOR 1

typedef struct PlatformMenuItem {
    uint32_t command_id;       // separator は 0
    uint8_t kind;              // PLATFORM_MENU_KIND_*
    const char* top_menu;      // トップメニュー名（例 "File"）。NUL 終端・呼び出し中のみ有効
    const char* label;         // 項目ラベル。separator は空文字可。NUL 終端・呼び出し中のみ有効
    int32_t shortcut_key;      // PlatformKeyCode。ショートカット無しは -1
    uint32_t shortcut_mods;    // PlatformModifierFlags。shortcut_key < 0 のとき無視
    uint8_t enabled;           // 0/1
    uint8_t checked;           // 0/1（トグル項目）
} PlatformMenuItem;

// このビルドで native メニューが利用可能か（VP_ENABLE_MENU かつ macOS native 実装あり）。
bool platform_menu_available(void);

// メニューバーを items[0..count) で差し替える（最後の登録が全体）。window は契約上無視。
void platform_register_menu(PlatformWindow* window, const PlatformMenuItem* items, uint32_t count);

// 登録済み項目の enabled/checked を command_id 照合で更新する（構造は変えない）。
void platform_update_menu(PlatformWindow* window, const PlatformMenuItem* items, uint32_t count);

// 登録済みメニューを破棄する（mainMenu を空に戻す）。
void platform_destroy_menu(PlatformWindow* window);

// ========================================
// ファイル選択ダイアログ (TASK-24)
// ========================================
//
// ネイティブのファイル選択ダイアログを同期モーダルで表示する（app-modal、
// ウィンドウ非依存）。呼び出しスレッド（メインスレッド）をブロックし、ユーザーが
// ダイアログを閉じるまで戻らない。フレームバッファ lock 中には呼ばないこと。

// 保存ダイアログのオプション
typedef struct PlatformSaveDialogOptions {
    const char* default_name;  // 初期ファイル名 (NULL 可)
    const char* allowed_ext;   // 拡張子フィルタ 例 "png" (NULL = 任意)
} PlatformSaveDialogOptions;

// 読み込みダイアログのオプション
typedef struct PlatformOpenDialogOptions {
    const char* allowed_ext;   // 拡張子フィルタ 例 "png" (NULL = 任意)
} PlatformOpenDialogOptions;

// 保存先をユーザーに選ばせる。
// 戻り値: 選択された絶対パス（NUL 終端、malloc 済み）。caller は platform_free_path() で解放。
//         キャンセル / エラー時は NULL。
char* platform_save_file_dialog(const PlatformSaveDialogOptions* opts);

// 開くファイルをユーザーに選ばせる（単一選択・ファイルのみ）。
// 戻り値: 選択された絶対パス（NUL 終端、malloc 済み）。caller は platform_free_path() で解放。
//         キャンセル / エラー時は NULL。
char* platform_open_file_dialog(const PlatformOpenDialogOptions* opts);

// platform_*_file_dialog() が返したパス文字列を解放する。NULL 安全。
void platform_free_path(char* path);

#endif // PLATFORM_H
