// The shared native menu bridge.
// The internal connection between platform_macos_menu.m and each macOS backend (objc/swift/metal).
// The public menu ABI in platform.h is unchanged.
#pragma once

#include "platform.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Backend specific: push a MENU_COMMAND onto that backend's own EventQueue.
// Called by the shared MenuTarget. window is the PlatformWindow* registered last.
void platform_menu_enqueue_command(PlatformWindow* window, uint32_t command_id);

// Shared: delegate performKeyEquivalent to the registered mainMenu.
// ns_event is an NSEvent* (ownership is not transferred). Returns true once consumed.
bool platform_menu_consume_key_equivalent(void* ns_event);

// Shared: call it just before a window is released. When that window is the delivery target,
// g_menu_event_window is set to NULL, which prevents a late MenuTarget action from using freed memory.
void platform_menu_window_will_destroy(PlatformWindow* window);

#ifdef __cplusplus
}
#endif
