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
// 注意: platform_unlock_framebuffer()を呼ぶまでバッファを保持
uint32_t* platform_lock_framebuffer(PlatformWindow* window, int* out_width, int* out_height);

// フレームバッファへのアクセスを終了
// platform_lock_framebuffer()とペアで使用
void platform_unlock_framebuffer(PlatformWindow* window);

// 画面を更新
// platform_lock_framebuffer()で書き込んだ内容を画面に表示
//
// 動作:
// - この関数は即座にリターンする（ブロッキングしない）
// - レンダリングシステム（WindowServer/GPU）が内部的に次のVBLANKで画面をスワップする
// - 書き込みバッファと表示バッファを分離しているため、いつ呼び出してもティアリングは発生しない
//
// 注意:
// - ゲームループのレート制御（何回呼ぶか）は呼び出し側の責任
// - フレームレート制限が必要な場合、platform_get_time()とsleep()を使用すること
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
} PlatformEventType;

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
    } payload;
} PlatformEvent;

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
