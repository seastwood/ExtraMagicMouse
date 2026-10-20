#include "CMultitouch.h"

#include <dlfcn.h>
#include <stddef.h>

#define FRAMEWORK_PATH "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
#define MAX_DEVICES 32

typedef CFMutableArrayRef (*CreateListFn)(void);
typedef void (*CallbackFn)(MTDeviceRef, MTContactCallbackFunction);
typedef void (*StartFn)(MTDeviceRef, int);
typedef void (*StopFn)(MTDeviceRef);
typedef bool (*IsBuiltInFn)(MTDeviceRef);

static bool loaded;
static bool loadFailed;
static CreateListFn createList;
static CallbackFn registerCallback;
static CallbackFn unregisterCallback;
static StartFn startDevice;
static StopFn stopDevice;
static IsBuiltInFn isBuiltIn; // optional

static CFMutableArrayRef deviceList;
static MTDeviceRef activeDevices[MAX_DEVICES];
static int activeCount;
static MTContactCallbackFunction activeCallback;

static bool load(void) {
    if (loaded) return true;
    if (loadFailed) return false;
    void *handle = dlopen(FRAMEWORK_PATH, RTLD_NOW);
    if (handle) {
        createList = (CreateListFn)dlsym(handle, "MTDeviceCreateList");
        registerCallback = (CallbackFn)dlsym(handle, "MTRegisterContactFrameCallback");
        unregisterCallback = (CallbackFn)dlsym(handle, "MTUnregisterContactFrameCallback");
        startDevice = (StartFn)dlsym(handle, "MTDeviceStart");
        stopDevice = (StopFn)dlsym(handle, "MTDeviceStop");
        isBuiltIn = (IsBuiltInFn)dlsym(handle, "MTDeviceIsBuiltIn");
    }
    loaded = handle && createList && registerCallback && unregisterCallback && startDevice && stopDevice;
    loadFailed = !loaded;
    return loaded;
}

bool EMMMultitouchAvailable(void) {
    return load();
}

int EMMMultitouchDeviceCount(void) {
    if (!load()) return 0;
    CFMutableArrayRef list = createList();
    if (!list) return 0;
    int count = (int)CFArrayGetCount(list);
    CFRelease(list);
    return count;
}

int EMMMultitouchStartAll(MTContactCallbackFunction callback, bool includeBuiltIn) {
    EMMMultitouchStopAll();
    if (!load()) return -1;
    deviceList = createList();
    if (!deviceList) return 0;
    CFIndex count = CFArrayGetCount(deviceList);
    for (CFIndex i = 0; i < count && activeCount < MAX_DEVICES; i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, i);
        if (!device) continue;
        if (!includeBuiltIn && isBuiltIn && isBuiltIn(device)) continue;
        registerCallback(device, callback);
        startDevice(device, 0);
        activeDevices[activeCount++] = device;
    }
    activeCallback = callback;
    return activeCount;
}

void EMMMultitouchStopAll(void) {
    for (int i = 0; i < activeCount; i++) {
        unregisterCallback(activeDevices[i], activeCallback);
        stopDevice(activeDevices[i]);
    }
    activeCount = 0;
    activeCallback = NULL;
    if (deviceList) {
        CFRelease(deviceList);
        deviceList = NULL;
    }
}

int64_t EMMEventIntegerField(CGEventRef event, uint32_t field) {
    return CGEventGetIntegerValueField(event, (CGEventField)field);
}
