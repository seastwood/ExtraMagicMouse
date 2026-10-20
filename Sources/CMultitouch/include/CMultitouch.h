#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

// Layout of one contact as reported by MultitouchSupport.framework
// (private; matches the struct used by MiddleClick and similar tools).
typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;      // 4 = touch began, 5 = touching; others are hover/lift
    int32_t fingerID;
    int32_t handID;
    MTVector normalized; // 0...1 across the touch surface
    float size;
    int32_t zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;   // millimetres
    int32_t zero2[2];
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef device, const MTTouch *touches,
                                         int32_t count, double timestamp, int32_t frame);

// True when the private framework and its symbols could be loaded.
bool EMMMultitouchAvailable(void);

// Number of multitouch devices macOS currently reports (all kinds).
int EMMMultitouchDeviceCount(void);

// Stops anything running, then registers `callback` on every device and starts
// it. Built-in trackpads are skipped unless `includeBuiltIn`. Returns the number
// of devices started, or -1 if the framework is unavailable.
int EMMMultitouchStartAll(MTContactCallbackFunction callback, bool includeBuiltIn);

void EMMMultitouchStopAll(void);

#endif
