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
// pixels: RGBA形式の32bitピクセル配列 (width * height)
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
// 戻り値: ピクセルバッファへのポインタ（RGBA形式、32bit）
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
} PlatformEventType;

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
        // 将来的にマウス、タッチなど追加
    } payload;
} PlatformEvent;

// イベント取得API（1つずつ）
// ウィンドウのイベントキューから1つイベントを取得する
// イベントがあればtrue、ないならfalseを返す
bool platform_get_event(PlatformWindow* window, PlatformEvent* event);

#endif // PLATFORM_H
