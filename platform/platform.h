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

// 画面を更新（vsync同期）
// platform_lock_framebuffer()で書き込んだ内容を画面に表示
// この関数はvsyncで待機する
void platform_present(PlatformWindow* window);

#endif // PLATFORM_H
