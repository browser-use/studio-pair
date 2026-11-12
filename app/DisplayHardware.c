#include "DisplayHardware.h"
#include <dlfcn.h>
#include <unistd.h>

typedef CGError (*ConfigureEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static ConfigureEnabled configurationFunction(void) {
    return (ConfigureEnabled)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
}

CGDirectDisplayID SPBuiltinDisplay(void) {
    CGDirectDisplayID displays[64]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(64, displays, &count) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < count; ++i)
        if (CGDisplayIsBuiltin(displays[i])) return displays[i];
    return 0;
}

unsigned SPStudioDisplayCount(void) {
    CGDirectDisplayID displays[64]; uint32_t count = 0; unsigned studios = 0;
    if (CGGetOnlineDisplayList(64, displays, &count) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < count; ++i) {
        CGDirectDisplayID id = displays[i];
        // Apple Studio Display, rather than any two external or virtual screens.
        if (!CGDisplayIsBuiltin(id) && CGDisplayIsActive(id) &&
            CGDisplayVendorNumber(id) == 0x610 && CGDisplayModelNumber(id) == 0xae3a &&
            CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay) ++studios;
    }
    return studios;
}

bool SPDisplayActive(CGDirectDisplayID display) { return CGDisplayIsActive(display); }
bool SPDisplayControlAvailable(void) { return configurationFunction() != NULL; }

int SPSetDisplayEnabled(CGDirectDisplayID display, bool enabled) {
    if (!display) return kCGErrorIllegalArgument;
    if (SPDisplayActive(display) == enabled) return 0;
    ConfigureEnabled configure = configurationFunction();
    if (!configure) return kCGErrorNotImplemented;
    CGDisplayConfigRef config = NULL;
    CGError error = CGBeginDisplayConfiguration(&config);
    if (error != kCGErrorSuccess) return error;
    error = configure(config, display, enabled);
    if (error != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); return error; }
    // Session-only: never store a disabled panel as the permanent display layout.
    error = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (error != kCGErrorSuccess) return error;
    for (unsigned attempt = 0; attempt < 30; ++attempt) {
        if (SPDisplayActive(display) == enabled) return 0;
        usleep(100000);
    }
    return kCGErrorFailure;
}
