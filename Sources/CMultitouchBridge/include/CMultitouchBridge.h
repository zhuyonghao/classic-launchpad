#ifndef C_MULTITOUCH_BRIDGE_H
#define C_MULTITOUCH_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t identifier;
    double x;
    double y;
} LPTrackpadContact;

// Contacts exist only during this call. Copy them before asynchronously dispatching.
// Called on a framework thread; do not call Start/Stop/Refresh from this callback.
// count == 0 means all contacts lifted; count == -1 means a malformed frame and
// must cancel/lock recognition until a later genuine zero-contact frame arrives.
// contacts is NULL for both zero and negative counts.
typedef void (*LPTrackpadCallback)(uintptr_t device,
                                  const LPTrackpadContact *contacts,
                                  int32_t count, double timestamp);

typedef struct {
    int32_t deviceCount;
    uint64_t frameCount;
    uint64_t rejectedFrameCount;
    uint64_t generation;
    int32_t maximumRawContactCount;
    int32_t maximumContactCount;
    uint32_t rejectionFlags;
} LPTrackpadDiagnostics;

enum {
    LPTrackpadErrorUnavailable = -1,
    LPTrackpadErrorInvalidCallback = -2,
    LPTrackpadErrorEnumeration = -3,
    LPTrackpadErrorResources = -4
};

// Availability means the private framework ABI symbols are present, not that a
// trackpad is connected or that macOS is delivering frames.
bool LPTrackpadAvailable(void);
// Start and Refresh return the current listener count, or a negative error above.
// Starting again with the same callback is an incremental refresh.
int32_t LPTrackpadStart(LPTrackpadCallback callback);
void LPTrackpadStop(void);
// Refresh preserves listeners for devices still present. It does not start a
// stopped bridge. Call after hotplug, or periodically while the bridge is active.
int32_t LPTrackpadRefresh(void);
// Thread-safe counters only: no coordinates or contact identities are retained.
LPTrackpadDiagnostics LPTrackpadGetDiagnostics(void);

#ifdef __cplusplus
}
#endif
#endif
