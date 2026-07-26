// ========================================
// The shared native menu implementation (NSMenu plus target-action)
// ========================================
//
// objc, swift and metal all link this same translation unit.
// Opt-in: build_helpers compiles this file only when enable_menu=true, passing
// `-DVP_ENABLE_MENU`. An executable that does not use menus never links this TU (nm shows no symbol).
// NSMenu needs no extra framework, since AppKit is linked already.
//
// Hot path declaration: building and rebuilding happen only on the first registration or a structural
// change; keyEquivalent matching only on a keyDown; a menu command only on a selection. None of it is per frame or real time.

#import <Cocoa/Cocoa.h>
#include "platform.h"
#include "macos/platform_macos_menu.h"
#include <string.h>

#if defined(VP_ENABLE_MENU)

static NSMenu* g_menu_main = nil;
static PlatformWindow* g_menu_event_window = NULL;

@interface MenuTarget : NSObject
- (void)onMenuCommand:(id)sender;
@end

@implementation MenuTarget
- (void)onMenuCommand:(id)sender {
    NSMenuItem* item = (NSMenuItem*)sender;
    if (!g_menu_event_window) return;
    // The EventQueue is backend specific. The shared TU only hands the command over through the bridge.
    platform_menu_enqueue_command(g_menu_event_window, (uint32_t)item.tag);
}
@end

static MenuTarget* g_menu_target = nil;

// KeyCode → NSMenuItem.keyEquivalent. A physical key code cannot be passed, so it maps to a character (a unichar).
// A key that cannot be converted gets no keyEquivalent (a menu item without a shortcut) plus a warning.
static BOOL menuKeyEquivalentForKey(int32_t key, NSString** out_eq) {
    if (key >= PLATFORM_KEY_A && key <= PLATFORM_KEY_Z) {
        char c = (char)('a' + (key - PLATFORM_KEY_A));
        *out_eq = [[NSString alloc] initWithBytes:&c length:1 encoding:NSASCIIStringEncoding];
        return YES;
    }
    if (key >= PLATFORM_KEY_0 && key <= PLATFORM_KEY_9) {
        char c = (char)('0' + (key - PLATFORM_KEY_0));
        *out_eq = [[NSString alloc] initWithBytes:&c length:1 encoding:NSASCIIStringEncoding];
        return YES;
    }
    unichar u = 0;
    switch (key) {
        case PLATFORM_KEY_ENTER:     u = NSCarriageReturnCharacter; break;
        case PLATFORM_KEY_ESCAPE:    u = 0x1b; break;
        case PLATFORM_KEY_BACKSPACE: u = NSBackspaceCharacter; break;
        case PLATFORM_KEY_DELETE:    u = NSDeleteCharacter; break;
        case PLATFORM_KEY_TAB:       u = NSTabCharacter; break;
        case PLATFORM_KEY_LEFT:      u = NSLeftArrowFunctionKey; break;
        case PLATFORM_KEY_RIGHT:     u = NSRightArrowFunctionKey; break;
        case PLATFORM_KEY_UP:        u = NSUpArrowFunctionKey; break;
        case PLATFORM_KEY_DOWN:      u = NSDownArrowFunctionKey; break;
        case PLATFORM_KEY_F1:  u = NSF1FunctionKey; break;
        case PLATFORM_KEY_F2:  u = NSF2FunctionKey; break;
        case PLATFORM_KEY_F3:  u = NSF3FunctionKey; break;
        case PLATFORM_KEY_F4:  u = NSF4FunctionKey; break;
        case PLATFORM_KEY_F5:  u = NSF5FunctionKey; break;
        case PLATFORM_KEY_F6:  u = NSF6FunctionKey; break;
        case PLATFORM_KEY_F7:  u = NSF7FunctionKey; break;
        case PLATFORM_KEY_F8:  u = NSF8FunctionKey; break;
        case PLATFORM_KEY_F9:  u = NSF9FunctionKey; break;
        case PLATFORM_KEY_F10: u = NSF10FunctionKey; break;
        case PLATFORM_KEY_F11: u = NSF11FunctionKey; break;
        case PLATFORM_KEY_F12: u = NSF12FunctionKey; break;
        case PLATFORM_KEY_F13: u = NSF13FunctionKey; break;
        case PLATFORM_KEY_F14: u = NSF14FunctionKey; break;
        case PLATFORM_KEY_F15: u = NSF15FunctionKey; break;
        case PLATFORM_KEY_F16: u = NSF16FunctionKey; break;
        case PLATFORM_KEY_F17: u = NSF17FunctionKey; break;
        case PLATFORM_KEY_F18: u = NSF18FunctionKey; break;
        case PLATFORM_KEY_F19: u = NSF19FunctionKey; break;
        case PLATFORM_KEY_F20: u = NSF20FunctionKey; break;
        default:
            NSLog(@"[video-proto] menu: unsupported keyEquivalent key=%d (item registered without shortcut)", (int)key);
            return NO;
    }
    *out_eq = [NSString stringWithCharacters:&u length:1];
    return YES;
}

static NSEventModifierFlags menuModifierMask(uint32_t mods) {
    NSEventModifierFlags mask = 0;
    if (mods & PLATFORM_MOD_SHIFT) mask |= NSEventModifierFlagShift;
    if (mods & PLATFORM_MOD_CTRL)  mask |= NSEventModifierFlagControl;
    if (mods & PLATFORM_MOD_ALT)   mask |= NSEventModifierFlagOption;
    if (mods & PLATFORM_MOD_CMD)   mask |= NSEventModifierFlagCommand;
    return mask;
}

static NSMenu* menuFindTopMenu(NSMenu* mainMenu, NSString* title) {
    for (NSMenuItem* item in mainMenu.itemArray) {
        if (item.submenu && [item.title isEqualToString:title]) return item.submenu;
    }
    return nil;
}

static NSMenu* menuEnsureTopMenu(NSMenu* mainMenu, NSString* title) {
    NSMenu* sub = menuFindTopMenu(mainMenu, title);
    if (sub) return sub;
    NSMenuItem* top = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    sub = [[NSMenu alloc] initWithTitle:title];
    [top setSubmenu:sub];
    [mainMenu addItem:top];
    return sub;
}

static void menuApplyItemState(NSMenuItem* item, const PlatformMenuItem* src) {
    [item setEnabled:src->enabled != 0];
    [item setState:(src->checked != 0) ? NSControlStateValueOn : NSControlStateValueOff];
}

/// UTF-8 → NSString. When stringWithUTF8String: returns nil for an invalid sequence (a truncated one
/// included), this falls back to an empty string, so no item goes missing and no invalid NSMenuItem is built.
static NSString* menuNSStringOrEmpty(const char* utf8, const char* field) {
    if (!utf8 || utf8[0] == '\0') return @"";
    NSString* s = [NSString stringWithUTF8String:utf8];
    if (!s) {
        NSLog(@"[video-proto] menu: invalid UTF-8 in %s — using empty string", field);
        return @"";
    }
    return s;
}

static NSMenuItem* menuMakeItem(const PlatformMenuItem* src) {
    if (src->kind == PLATFORM_MENU_KIND_SEPARATOR) {
        return [NSMenuItem separatorItem];
    }
    NSString* label = menuNSStringOrEmpty(src->label, "label");
    NSString* keyEq = @"";
    NSEventModifierFlags keyMask = 0;
    if (src->shortcut_key >= 0) {
        NSString* eq = nil;
        if (menuKeyEquivalentForKey(src->shortcut_key, &eq)) {
            keyEq = eq;
            keyMask = menuModifierMask(src->shortcut_mods);
        }
    }
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:label
                                                  action:@selector(onMenuCommand:)
                                           keyEquivalent:keyEq];
    [item setKeyEquivalentModifierMask:keyMask];
    [item setTag:(NSInteger)src->command_id];
    [item setTarget:g_menu_target];
    menuApplyItemState(item, src);
    return item;
}

bool platform_menu_available(void) {
    return true;
}

void platform_register_menu(PlatformWindow* window, const PlatformMenuItem* items, uint32_t count) {
    @autoreleasepool {
        if (!g_menu_target) g_menu_target = [[MenuTarget alloc] init];
        // The menu bar belongs to the application, so events go to the window of the last registration.
        if (window) g_menu_event_window = window;

        // Under a manual event pump (calling nextEventMatchingMask directly) finishLaunching is never
        // called, and setMainMenu does not attach the bar to the menu bar. Only for an application that
        // uses menus, the launched state is set once here (the behaviour of a non-menu application is
        // unchanged).
        static bool s_menu_finish_launching_done = false;
        if (!s_menu_finish_launching_done) {
            s_menu_finish_launching_done = true;
            [NSApp finishLaunching];
        }

        NSMenu* mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
        // AppKit puts the first item of mainMenu into the "application name menu" slot. Without an
        // application menu in front, the first registered menu (File) is swallowed under the application
        // name and becomes invisible. Quit goes through performClose: (first responder = the key window,
        // reaching the existing windowShouldClose → quit event path) rather than NSApp terminate:, so that
        // the application's unsaved-changes flow is not skipped.
        {
            NSMenuItem* app_item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
            NSMenu* app_menu = [[NSMenu alloc] initWithTitle:@""];
            NSString* app_name = [[NSProcessInfo processInfo] processName];
            NSMenuItem* quit_item =
                [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", app_name]
                                           action:@selector(performClose:)
                                    keyEquivalent:@"q"];
            [app_menu addItem:quit_item];
            [app_item setSubmenu:app_menu];
            [mainMenu addItem:app_item];
        }
        if (items && count > 0) {
            for (uint32_t i = 0; i < count; i++) {
                const PlatformMenuItem* src = &items[i];
                NSString* top = menuNSStringOrEmpty(src->top_menu, "top_menu");
                if (top.length == 0) {
                    // An empty or invalid UTF-8 top-level name falls back to "Menu" (the items are kept)
                    if (src->top_menu && src->top_menu[0] != '\0') {
                        NSLog(@"[video-proto] menu: empty/invalid top_menu — fallback to \"Menu\"");
                    }
                    top = @"Menu";
                }
                NSMenu* sub = menuEnsureTopMenu(mainMenu, top);
                [sub addItem:menuMakeItem(src)];
            }
        }
        g_menu_main = mainMenu;
        [NSApp setMainMenu:mainMenu];
    }
}

void platform_update_menu(PlatformWindow* window, const PlatformMenuItem* items, uint32_t count) {
    (void)window;
    @autoreleasepool {
        if (!g_menu_main || !items) return;
        for (uint32_t i = 0; i < count; i++) {
            const PlatformMenuItem* src = &items[i];
            if (src->kind == PLATFORM_MENU_KIND_SEPARATOR) continue;
            if (src->command_id == 0) continue;
            // Walk every top menu and update the item whose tag is command_id
            for (NSMenuItem* top in g_menu_main.itemArray) {
                NSMenu* sub = top.submenu;
                if (!sub) continue;
                NSMenuItem* found = [sub itemWithTag:(NSInteger)src->command_id];
                if (found) {
                    menuApplyItemState(found, src);
                    break;
                }
            }
        }
    }
}

void platform_destroy_menu(PlatformWindow* window) {
    (void)window;
    @autoreleasepool {
        g_menu_main = nil;
        g_menu_event_window = NULL;
        [NSApp setMainMenu:[[NSMenu alloc] initWithTitle:@""]];
    }
}

void platform_menu_window_will_destroy(PlatformWindow* window) {
    // Detach only when the target is the current delivery window (a registration by another window is kept).
    // From then on a MenuTarget action sees g_menu_event_window==NULL and discards the enqueue.
    if (window && g_menu_event_window == window) {
        g_menu_event_window = NULL;
    }
}

bool platform_menu_consume_key_equivalent(void* ns_event) {
    if (!g_menu_main || !ns_event) return false;
    NSEvent* event = (__bridge NSEvent*)ns_event;
    return [g_menu_main performKeyEquivalent:event] ? true : false;
}

#endif // VP_ENABLE_MENU
