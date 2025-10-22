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

#endif // PLATFORM_H
