#include "CMultitouchBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// Independently implemented bridge. ABI facts were checked against:
// https://github.com/SomeGuyNamedDaveIsTaken/macOSMiddleClick/blob/main/middleclick.c
// https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h
// This is an undocumented system ABI, so missing symbols fail closed. The static
// assertions verify our compiler's layout; they cannot guarantee future OS ABI.
typedef struct { float x, y; } LPPoint;
typedef struct { LPPoint position, velocity; } LPReadout;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier, state, reserved1, reserved2;
    LPReadout normalized;
    float size;
    int32_t reserved3;
    float angle, majorAxis, minorAxis;
    LPReadout millimeters;
    int32_t reserved4[2];
    float reserved5;
} LPSystemFinger;

_Static_assert(sizeof(LPSystemFinger) == 96, "Unexpected multitouch contact stride");
_Static_assert(offsetof(LPSystemFinger, timestamp) == 8, "Unexpected timestamp offset");
_Static_assert(offsetof(LPSystemFinger, identifier) == 16, "Unexpected identifier offset");
_Static_assert(offsetof(LPSystemFinger, state) == 20, "Unexpected state offset");
_Static_assert(offsetof(LPSystemFinger, normalized) == 32, "Unexpected position offset");

typedef void *LPDevice;
typedef int (*LPSystemCallback)(LPDevice, LPSystemFinger *, int, double, int);
typedef CFArrayRef (*LPCreateList)(void);
typedef void (*LPRegister)(LPDevice, LPSystemCallback);
typedef void (*LPStart)(LPDevice, int);
typedef void (*LPStop)(LPDevice);
typedef int (*LPDimensions)(LPDevice, int *, int *);
typedef int (*LPDeviceID)(LPDevice, uint64_t *);

static struct {
    void *handle;
    LPCreateList createList;
    LPRegister registerCallback, unregisterCallback;
    LPStart start;
    LPStop stop;
    LPDimensions sensorDimensions, surfaceDimensions;
    LPDeviceID deviceID;
    bool available;
} systemAPI;
static pthread_once_t loadOnce = PTHREAD_ONCE_INIT;

enum { LPMaxDevices = 32, LPMaxContacts = 32 };
typedef struct {
    LPDevice device;
    uint64_t identity;
    bool hasIdentity, enabled;
    uint32_t inFlight;
} LPListener;

// Lifecycle calls are serialized separately from callback bookkeeping. Never
// hold frameMutex while calling the private framework or the Swift callback.
static pthread_mutex_t lifecycleMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t frameMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t framesFinished = PTHREAD_COND_INITIALIZER;
static LPListener *listeners[LPMaxDevices];
static int32_t listenerCount;
static LPTrackpadCallback consumer;
static bool running;
static LPTrackpadDiagnostics diagnostics;

static void loadFramework(void) {
    static const char *paths[] = {
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport",
        "/System/Library/PrivateFrameworks/MultitouchSupportPrivate.framework/MultitouchSupportPrivate"
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); ++i) {
        systemAPI.handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
        if (systemAPI.handle != NULL) break;
    }
    if (systemAPI.handle == NULL) return;
    systemAPI.createList = (LPCreateList)dlsym(systemAPI.handle, "MTDeviceCreateList");
    systemAPI.registerCallback = (LPRegister)dlsym(systemAPI.handle, "MTRegisterContactFrameCallback");
    systemAPI.unregisterCallback = (LPRegister)dlsym(systemAPI.handle, "MTUnregisterContactFrameCallback");
    systemAPI.start = (LPStart)dlsym(systemAPI.handle, "MTDeviceStart");
    systemAPI.stop = (LPStop)dlsym(systemAPI.handle, "MTDeviceStop");
    systemAPI.sensorDimensions = (LPDimensions)dlsym(systemAPI.handle, "MTDeviceGetSensorDimensions");
    systemAPI.surfaceDimensions = (LPDimensions)dlsym(systemAPI.handle, "MTDeviceGetSensorSurfaceDimensions");
    systemAPI.deviceID = (LPDeviceID)dlsym(systemAPI.handle, "MTDeviceGetDeviceID");
    systemAPI.available = systemAPI.createList && systemAPI.registerCallback &&
        systemAPI.unregisterCallback && systemAPI.start && systemAPI.stop &&
        systemAPI.sensorDimensions && systemAPI.surfaceDimensions;
    // Keep the framework loaded for the entire process lifetime, including after
    // stopping. An undocumented framework may retain asynchronous work internally.
}

bool LPTrackpadAvailable(void) {
    pthread_once(&loadOnce, loadFramework);
    return systemAPI.available;
}

LPTrackpadDiagnostics LPTrackpadGetDiagnostics(void) {
    pthread_mutex_lock(&frameMutex);
    LPTrackpadDiagnostics value = diagnostics;
    pthread_mutex_unlock(&frameMutex);
    return value;
}

static int receiveFrame(LPDevice device, LPSystemFinger *fingers, int count,
                        double timestamp, int frame) {
    (void)frame;
    pthread_mutex_lock(&frameMutex);
    LPListener *source = NULL;
    if (running && consumer != NULL) {
        for (int32_t i = 0; i < listenerCount; ++i) {
            if (listeners[i]->enabled && listeners[i]->device == device) {
                source = listeners[i];
                break;
            }
        }
    }
    if (source == NULL) {
        pthread_mutex_unlock(&frameMutex);
        return 0;
    }
    ++source->inFlight;
    ++diagnostics.frameCount;
    LPTrackpadCallback callback = consumer;
    pthread_mutex_unlock(&frameMutex);

    LPTrackpadContact contacts[LPMaxContacts];
    int32_t accepted = 0;
    bool invalid = count < 0 || count > LPMaxContacts || !isfinite(timestamp) || timestamp < 0 ||
        (count > 0 && fingers == NULL);
    if (!invalid) {
        for (int i = 0; i < count; ++i) {
            const LPSystemFinger *finger = &fingers[i];
            if (finger->state < 0 || finger->state > 7) { invalid = true; break; }
            if (finger->state != 3 && finger->state != 4) continue;
            const double x = finger->normalized.position.x;
            const double y = finger->normalized.position.y;
            if (finger->identifier < 0 || !isfinite(x) || !isfinite(y) ||
                x < 0 || x > 1 || y < 0 || y > 1) { invalid = true; break; }
            for (int32_t j = 0; j < accepted; ++j) {
                if (contacts[j].identifier == finger->identifier) { invalid = true; break; }
            }
            if (invalid) break;
            contacts[accepted++] = (LPTrackpadContact){finger->identifier, x, y};
        }
    }
    // A malformed frame must lock recognition, not impersonate a genuine lift
    // or turn a corrupt five-contact frame into a valid four-contact frame.
    if (invalid) accepted = -1;
    pthread_mutex_lock(&frameMutex);
    if (invalid) ++diagnostics.rejectedFrameCount;
    const bool deliver = running && source->enabled && consumer == callback;
    pthread_mutex_unlock(&frameMutex);
    if (deliver) callback((uintptr_t)device, accepted > 0 ? contacts : NULL,
                          accepted, isfinite(timestamp) ? timestamp : 0);

    pthread_mutex_lock(&frameMutex);
    --source->inFlight;
    if (source->inFlight == 0) pthread_cond_broadcast(&framesFinished);
    pthread_mutex_unlock(&frameMutex);
    return 0;
}

static bool isTrackpad(LPDevice device) {
    int rows = 0, columns = 0, width = 0, height = 0;
    if (systemAPI.sensorDimensions(device, &rows, &columns) != 0 ||
        systemAPI.surfaceDimensions(device, &width, &height) != 0) return false;
    // Touch Bars are a narrow strip (typically two sensor rows). Magic Mouse has
    // a portrait surface, while built-in and Magic Trackpads are landscape.
    // Compare ratios only; the undocumented surface units vary by device.
    return rows >= 10 && columns >= 10 && rows <= 1024 && columns <= 1024 &&
           width > 0 && height > 0 && width >= height;
}

static bool sameDevice(const LPListener *a, const LPListener *b) {
    if (a->hasIdentity && b->hasIdentity) return a->identity == b->identity;
    return a->device == b->device;
}

// lifecycleMutex must be held. The listener must first be disabled under
// frameMutex, and its entry remains present until all in-flight calls return.
static void retireListener(LPListener *listener) {
    systemAPI.unregisterCallback(listener->device, receiveFrame);
    systemAPI.stop(listener->device);
    pthread_mutex_lock(&frameMutex);
    while (listener->inFlight != 0) pthread_cond_wait(&framesFinished, &frameMutex);
    for (int32_t i = 0; i < listenerCount; ++i) {
        if (listeners[i] == listener) {
            memmove(&listeners[i], &listeners[i + 1],
                    (size_t)(listenerCount - i - 1) * sizeof(listeners[0]));
            --listenerCount;
            diagnostics.deviceCount = listenerCount;
            break;
        }
    }
    pthread_mutex_unlock(&frameMutex);
    CFRelease(listener->device);
    free(listener);
}

static void stopLocked(void) {
    pthread_mutex_lock(&frameMutex);
    const bool changed = running || listenerCount > 0;
    running = false;
    consumer = NULL;
    for (int32_t i = 0; i < listenerCount; ++i) listeners[i]->enabled = false;
    if (changed) ++diagnostics.generation;
    pthread_mutex_unlock(&frameMutex);
    while (listenerCount > 0) retireListener(listeners[listenerCount - 1]);
}

void LPTrackpadStop(void) {
    pthread_mutex_lock(&lifecycleMutex);
    stopLocked();
    pthread_mutex_unlock(&lifecycleMutex);
}

// lifecycleMutex must be held. Preserve old listeners if enumeration fails.
static int32_t refreshLocked(void) {
    if (!running) return 0;
    CFArrayRef devices = systemAPI.createList();
    if (devices == NULL) return LPTrackpadErrorEnumeration;
    const CFIndex count = CFArrayGetCount(devices);
    if (count < 0 || count > 1024) {
        CFRelease(devices);
        return LPTrackpadErrorEnumeration;
    }
    LPListener candidates[LPMaxDevices];
    int32_t candidateCount = 0;
    for (CFIndex i = 0; i < count; ++i) {
        LPDevice device = (LPDevice)CFArrayGetValueAtIndex(devices, i);
        if (device == NULL || !isTrackpad(device)) continue;
        LPListener value = {0};
        value.device = device;
        value.hasIdentity = systemAPI.deviceID &&
            systemAPI.deviceID(device, &value.identity) == 0 && value.identity != 0;
        bool duplicate = false;
        for (int32_t j = 0; j < candidateCount; ++j) {
            if (sameDevice(&value, &candidates[j])) { duplicate = true; break; }
        }
        if (duplicate) continue;
        if (candidateCount == LPMaxDevices) {
            CFRelease(devices);
            return LPTrackpadErrorResources;
        }
        candidates[candidateCount++] = value;
    }
    bool changed = false;
    for (int32_t i = listenerCount - 1; i >= 0; --i) {
        LPListener *listener = listeners[i];
        bool found = false;
        for (int32_t j = 0; j < candidateCount; ++j) {
            if (sameDevice(listener, &candidates[j])) { found = true; break; }
        }
        if (!found) {
            pthread_mutex_lock(&frameMutex);
            listener->enabled = false;
            pthread_mutex_unlock(&frameMutex);
            retireListener(listener);
            changed = true;
        }
    }
    int32_t error = 0;
    for (int32_t i = 0; i < candidateCount; ++i) {
        bool found = false;
        for (int32_t j = 0; j < listenerCount; ++j) {
            if (sameDevice(listeners[j], &candidates[i])) { found = true; break; }
        }
        if (found) continue;
        LPListener *listener = calloc(1, sizeof(*listener));
        if (listener == NULL) { error = LPTrackpadErrorResources; break; }
        *listener = candidates[i];
        CFRetain(listener->device);
        systemAPI.registerCallback(listener->device, receiveFrame);
        pthread_mutex_lock(&frameMutex);
        listener->enabled = true;
        listeners[listenerCount++] = listener;
        diagnostics.deviceCount = listenerCount;
        pthread_mutex_unlock(&frameMutex);
        systemAPI.start(listener->device, 0);
        changed = true;
    }
    CFRelease(devices);
    if (changed) {
        pthread_mutex_lock(&frameMutex);
        ++diagnostics.generation;
        pthread_mutex_unlock(&frameMutex);
    }
    return error ? error : listenerCount;
}

int32_t LPTrackpadStart(LPTrackpadCallback callback) {
    if (callback == NULL) return LPTrackpadErrorInvalidCallback;
    if (!LPTrackpadAvailable()) return LPTrackpadErrorUnavailable;
    pthread_mutex_lock(&lifecycleMutex);
    if (running && consumer != callback) stopLocked();
    if (!running) {
        pthread_mutex_lock(&frameMutex);
        consumer = callback;
        running = true;
        diagnostics.frameCount = 0;
        diagnostics.rejectedFrameCount = 0;
        ++diagnostics.generation;
        pthread_mutex_unlock(&frameMutex);
    }
    const int32_t result = refreshLocked();
    pthread_mutex_unlock(&lifecycleMutex);
    return result;
}

int32_t LPTrackpadRefresh(void) {
    pthread_mutex_lock(&lifecycleMutex);
    const int32_t result = refreshLocked();
    pthread_mutex_unlock(&lifecycleMutex);
    return result;
}
