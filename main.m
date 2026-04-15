#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <AppKit/AppKit.h>
#include <signal.h>
#include <syslog.h>

#define MAX_MAPPINGS 20
#define CONFIG_LINE_MAX 1024

typedef struct {
    int keycode;
    char app_path[1024];
    char bundle_id[256];
} HotkeyMapping;

static HotkeyMapping g_mappings[MAX_MAPPINGS];
static int g_mapping_count = 0;
static CFMachPortRef g_event_tap = NULL;

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

static int fkey_to_keycode(const char *name) {
    static const struct { const char *name; int code; } map[] = {
        {"F1",  kVK_F1},  {"F2",  kVK_F2},  {"F3",  kVK_F3},
        {"F4",  kVK_F4},  {"F5",  kVK_F5},  {"F6",  kVK_F6},
        {"F7",  kVK_F7},  {"F8",  kVK_F8},  {"F9",  kVK_F9},
        {"F10", kVK_F10}, {"F11", kVK_F11}, {"F12", kVK_F12},
    };
    for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        if (strcasecmp(name, map[i].name) == 0) return map[i].code;
    }
    return -1;
}

static void trim(char *s) {
    // leading
    char *start = s;
    while (*start == ' ' || *start == '\t') start++;
    if (start != s) memmove(s, start, strlen(start) + 1);
    // trailing
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == ' ' || s[len - 1] == '\t'))
        s[--len] = '\0';
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

static int resolve_bundle_id(const char *app_path, char *out, size_t out_len) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:app_path];
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (!bundle || !bundle.bundleIdentifier) return -1;
        strlcpy(out, bundle.bundleIdentifier.UTF8String, out_len);
        return 0;
    }
}

static void load_config(void) {
    const char *home = getenv("HOME");
    if (!home) {
        syslog(LOG_ERR, "HOME not set");
        return;
    }

    char path[1024];
    snprintf(path, sizeof(path), "%s/.macos-hotkeys.conf", home);

    FILE *f = fopen(path, "r");
    if (!f) {
        syslog(LOG_ERR, "Cannot open config: %s", path);
        return;
    }

    g_mapping_count = 0;
    char line[CONFIG_LINE_MAX];

    while (fgets(line, sizeof(line), f) && g_mapping_count < MAX_MAPPINGS) {
        // strip newline
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';

        trim(line);
        if (len == 0 || line[0] == '#') continue;

        char *eq = strchr(line, '=');
        if (!eq) {
            syslog(LOG_WARNING, "Invalid config line: %s", line);
            continue;
        }

        *eq = '\0';
        char *key = line;
        char *val = eq + 1;
        trim(key);
        trim(val);

        int keycode = fkey_to_keycode(key);
        if (keycode < 0) {
            syslog(LOG_WARNING, "Unknown key: %s", key);
            continue;
        }

        HotkeyMapping *m = &g_mappings[g_mapping_count];
        m->keycode = keycode;
        strlcpy(m->app_path, val, sizeof(m->app_path));

        if (resolve_bundle_id(val, m->bundle_id, sizeof(m->bundle_id)) != 0) {
            syslog(LOG_WARNING, "Cannot resolve bundle ID for: %s", val);
            continue;
        }

        syslog(LOG_INFO, "Mapped %s -> %s (%s)", key, m->app_path, m->bundle_id);
        g_mapping_count++;
    }

    fclose(f);
    syslog(LOG_INFO, "Loaded %d hotkey mapping(s)", g_mapping_count);
}

// ---------------------------------------------------------------------------
// App activation
// ---------------------------------------------------------------------------

static void launch_app(const char *app_path) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:app_path];
        NSURL *url = [NSURL fileURLWithPath:path];
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                              configuration:config
                                          completionHandler:^(NSRunningApplication *app, NSError *err) {
            if (err) {
                syslog(LOG_ERR, "Failed to launch %s: %s",
                       app_path, err.localizedDescription.UTF8String);
            } else {
                syslog(LOG_INFO, "Launched %s (pid %d)", app_path, app.processIdentifier);
            }
        }];
    }
}

static void cycle_windows(pid_t pid) {
    AXUIElementRef axApp = AXUIElementCreateApplication(pid);
    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute,
                                                 (CFTypeRef *)&windows);
    if (err != kAXErrorSuccess || !windows) {
        if (windows) CFRelease(windows);
        CFRelease(axApp);
        return;
    }

    // collect non-minimized windows
    CFMutableArrayRef visible = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CFBooleanRef minimized = NULL;
        AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, (CFTypeRef *)&minimized);
        BOOL isMin = (minimized == kCFBooleanTrue);
        if (minimized) CFRelease(minimized);
        if (!isMin) CFArrayAppendValue(visible, win);
    }

    if (CFArrayGetCount(visible) > 1) {
        // raise the backmost visible window → cycles through all windows
        AXUIElementRef back = (AXUIElementRef)CFArrayGetValueAtIndex(
            visible, CFArrayGetCount(visible) - 1);
        AXUIElementPerformAction(back, kAXRaiseAction);
        AXUIElementSetAttributeValue(back, kAXMainAttribute, kCFBooleanTrue);
        syslog(LOG_INFO, "Cycled window for pid %d", pid);
    }

    CFRelease(visible);
    CFRelease(windows);
    CFRelease(axApp);
}

static void handle_hotkey(HotkeyMapping *mapping) {
    @autoreleasepool {
        NSString *bundleID = [NSString stringWithUTF8String:mapping->bundle_id];
        NSArray<NSRunningApplication *> *apps =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];

        if (apps.count == 0) {
            syslog(LOG_INFO, "App not running, launching: %s", mapping->app_path);
            launch_app(mapping->app_path);
            return;
        }

        NSRunningApplication *frontApp =
            [[NSWorkspace sharedWorkspace] frontmostApplication];
        BOOL isActive = [frontApp.bundleIdentifier isEqualToString:bundleID];

        if (isActive) {
            // already frontmost → cycle windows
            cycle_windows(frontApp.processIdentifier);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [frontApp activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
        } else {
            // bring MRU window to front
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [apps[0] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
            syslog(LOG_INFO, "Activated %s", mapping->bundle_id);
        }
    }
}

// ---------------------------------------------------------------------------
// Event tap
// ---------------------------------------------------------------------------

static CGEventRef event_callback(CGEventTapProxy proxy, CGEventType type,
                                  CGEventRef event, void *userInfo) {
    (void)proxy;
    (void)userInfo;

    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        syslog(LOG_WARNING, "Event tap disabled, re-enabling");
        CGEventTapEnable(g_event_tap, true);
        return event;
    }

    if (type != kCGEventKeyDown) return event;

    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    for (int i = 0; i < g_mapping_count; i++) {
        if (g_mappings[i].keycode == (int)keycode) {
            handle_hotkey(&g_mappings[i]);
            return NULL; // swallow the event
        }
    }

    return event;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

static bool check_accessibility(void) {
    @autoreleasepool {
        NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    }
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    openlog("macos-hotkeys", LOG_PID | LOG_NDELAY, LOG_USER);
    syslog(LOG_INFO, "Starting macos-hotkeys");

    @autoreleasepool {
        if (!check_accessibility()) {
            syslog(LOG_WARNING,
                   "Accessibility not granted – will prompt, "
                   "restart after granting permission");
            fprintf(stderr,
                    "Accessibility permission required.\n"
                    "Grant access in System Settings > Privacy & Security > "
                    "Accessibility, then restart.\n");
        }

        load_config();
        if (g_mapping_count == 0) {
            syslog(LOG_ERR, "No valid hotkey mappings found");
            fprintf(stderr, "No valid hotkey mappings in ~/.macos-hotkeys.conf\n");
            return 1;
        }

        // SIGHUP → reload config (via dispatch source on main queue)
        signal(SIGHUP, SIG_IGN);
        dispatch_source_t sig = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sig, ^{
            syslog(LOG_INFO, "Reloading configuration (SIGHUP)");
            load_config();
        });
        dispatch_resume(sig);

        // create global event tap
        CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
        g_event_tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionDefault,
            mask,
            event_callback,
            NULL);

        if (!g_event_tap) {
            syslog(LOG_ERR, "Failed to create event tap");
            fprintf(stderr,
                    "Failed to create event tap. "
                    "Grant Accessibility permission in System Settings > "
                    "Privacy & Security > Accessibility.\n");
            return 1;
        }

        CFRunLoopSourceRef src =
            CFMachPortCreateRunLoopSource(NULL, g_event_tap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
        CGEventTapEnable(g_event_tap, true);
        CFRelease(src);

        syslog(LOG_INFO, "Event tap active, entering run loop");
        CFRunLoopRun();
    }

    closelog();
    return 0;
}
