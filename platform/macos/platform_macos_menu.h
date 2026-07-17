// Shared native menu bridge (TASK-122)。
// platform_macos_menu.m と各 macOS backend（objc/swift/metal）の内部接続。
// platform.h の公開 menu ABI は変更しない。
#pragma once

#include "platform.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Backend 固有: MENU_COMMAND を自身の EventQueue へ積む。
// 共有 MenuTarget から呼ばれる。window は最後に register した PlatformWindow*。
void platform_menu_enqueue_command(PlatformWindow* window, uint32_t command_id);

// 共有実装: 登録済み mainMenu へ performKeyEquivalent を委譲。
// ns_event は NSEvent*（所有権は渡さない）。消費したら true。
bool platform_menu_consume_key_equivalent(void* ns_event);

// 共有実装: window 解放直前に呼ぶ。配送先が当該 window なら g_menu_event_window を
// NULL 化し、遅延 MenuTarget action の use-after-free を防ぐ（TASK-122 r2）。
void platform_menu_window_will_destroy(PlatformWindow* window);

#ifdef __cplusplus
}
#endif
