#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

CGDirectDisplayID SPBuiltinDisplay(void);
unsigned SPStudioDisplayCount(void);
bool SPDisplayActive(CGDirectDisplayID display);
bool SPDisplayControlAvailable(void);
int SPSetDisplayEnabled(CGDirectDisplayID display, bool enabled);
