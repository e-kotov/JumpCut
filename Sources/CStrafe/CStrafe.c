// CStrafe.c — implementation of the synthetic dock-swipe mechanism.
//
// An independent reimplementation of the technique from
// jurplel/InstantSpaceSwitcher (MIT). Every magic number here is documented in
// docs/SPEC.md §1–2. Treat the field indices and event-type values as
// version-fragile (SPEC §7).

#include "CStrafe.h"
#include "IOHIDPayload.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CGEventTypes.h>
#include <CoreFoundation/CoreFoundation.h>
#include <float.h>
#include <string.h>

// --- Private CGEventField indices (SPEC §1.2) -----------------------------
static const CGEventField kCGSEventTypeField           = (CGEventField)55;   // private CGSEventType selector
static const CGEventField kCGEventGestureHIDType       = (CGEventField)110;  // IOHIDEvent gesture type
static const CGEventField kCGEventGestureSwipeMotion   = (CGEventField)123;  // motion axis (horizontal=1)
static const CGEventField kCGEventGestureSwipeProgress = (CGEventField)124;  // gesture progress (double)
static const CGEventField kCGEventGestureSwipeVelocityX= (CGEventField)129;  // (double)
static const CGEventField kCGEventGestureSwipeVelocityY= (CGEventField)130;  // (double)
static const CGEventField kCGEventGesturePhase         = (CGEventField)132;  // CGSGesturePhase
static const CGEventField kCGEventGestureSwipePositionX = (CGEventField)125;
static const CGEventField kCGEventGesturePhaseAlias     = (CGEventField)134;
static const CGEventField kCGEventGestureZoomDeltaY     = (CGEventField)138;

// --- Type / enum constants (SPEC §1.3) ------------------------------------
static const uint32_t kIOHIDEventTypeDockSwipe = 23;   // written into field 110
// Marker applied after serialization; distinguishes our synthetic gestures.
static const int64_t kJumpCutSyntheticTag = 0x4A554D50; // 'JUMP'

enum {
    kCGSEventScrollWheel       = 22,
    kCGSEventZoom              = 28,
    kCGSEventGesture           = 29,
    kCGSEventDockControl       = 30,   // the dock-swipe type we synthesize + intercept
    kCGSEventFluidTouchGesture = 31,
};

typedef CF_ENUM(uint8_t, CGSGesturePhase) {
    kCGSGesturePhaseNone      = 0,
    kCGSGesturePhaseBegan     = 1,
    kCGSGesturePhaseChanged   = 2,
    kCGSGesturePhaseEnded     = 4,
    kCGSGesturePhaseCancelled = 8,
    kCGSGesturePhaseMayBegin  = 128,
};

typedef CF_ENUM(uint16_t, CGGestureMotion) {
    kCGGestureMotionHorizontal = 1,
};

// --- Weak-imported CGS symbols for space topology (SPEC §1.1) -------------
typedef int32_t  CGSConnectionID;
typedef uint64_t CGSSpaceID;
extern CFArrayRef  CGSCopyManagedDisplaySpaces(CGSConnectionID connection, CFStringRef display) __attribute__((weak_import));
extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));

bool strafe_cgs_available(void) {
    return (&CGSMainConnectionID != NULL) &&
           (&CGSCopyManagedDisplaySpaces != NULL);
}

// --- Synthesis (SPEC §1.5) ------------------------------------------------
#include <math.h>
#include <stdlib.h>
#include <unistd.h>

#ifdef JUMPCUT_PREPARATION_TESTING
#include "PreparationTestHooks.h"
#define calloc strafe_test_calloc
#define free strafe_test_free
#define CGEventCreate strafe_test_event_create
#define CGEventSetIntegerValueField strafe_test_set_integer
#define CFRelease strafe_test_release
#define usleep strafe_test_usleep
#endif

bool strafe_uses_iohid_payload(void) {
#ifdef JUMPCUT_PREPARATION_TESTING
    return strafe_test_uses_iohid_payload();
#else
    if (__builtin_available(macOS 27.0, *)) { return true; }
    return false;
#endif
}

// Sample once per preparation, so changing the preference cannot reverse a
// gesture halfway through. An absent preference means macOS's default (on).
static bool natural_scrolling_enabled(void) {
#ifdef JUMPCUT_PREPARATION_TESTING
    return strafe_test_natural_scrolling_enabled();
#else
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication);
    if (!value) { return true; }
    bool enabled = true;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 1;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        enabled = number != 0;
    }
    CFRelease(value);
    return enabled;
#endif
}

// Inherited macOS 27 convention: outgoing events compensate for Natural
// Scrolling; incoming physical gesture signs are handled independently.
bool strafe_posted_sign_reversed(void) {
    return strafe_uses_iohid_payload() && natural_scrolling_enabled();
}

typedef struct {
    CGEventRef dock;
    CGEventRef companion;
    uint32_t delayAfterMicroseconds;
} PreparedPhase;

struct StrafePreparedGesture {
    uint32_t phaseCount;
    PreparedPhase phases[];
};

static void free_phase(PreparedPhase *phase) {
    if (phase->dock) { CFRelease(phase->dock); }
    if (phase->companion) { CFRelease(phase->companion); }
}

void strafe_free_prepared_gesture(StrafePreparedGesture *gesture) {
    if (!gesture) { return; }
    for (uint32_t i = 0; i < gesture->phaseCount; i++) {
        free_phase(&gesture->phases[i]);
    }
    free(gesture);
}

static StrafePreparedGesture *allocate_gesture(size_t phaseCount) {
    if (phaseCount > UINT32_MAX
        || phaseCount > (SIZE_MAX - sizeof(StrafePreparedGesture)) / sizeof(PreparedPhase)) {
        return NULL;
    }
    size_t size = sizeof(StrafePreparedGesture) + phaseCount * sizeof(PreparedPhase);
    StrafePreparedGesture *gesture = calloc(1, size);
    if (gesture) { gesture->phaseCount = (uint32_t)phaseCount; }
    return gesture;
}

// On failure, the caller frees the entire zero-initialized gesture. Ownership
// stays in `out` even if augmentation or companion creation fails late.
static bool prepare_phase(PreparedPhase *out, CGSGesturePhase phase,
                          double progress, double velocity, bool augmented, bool reversed) {
    if (reversed) { progress = -progress; velocity = -velocity; }
    out->dock = CGEventCreate(NULL);
    if (!out->dock) { return false; }
    CGEventRef ev = out->dock;
    CGEventSetIntegerValueField(ev, kCGSEventTypeField,            kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType,        kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase,          phase);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeProgress,  progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion,    kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityX, velocity);
    CGEventSetDoubleValueField (ev, kCGEventGestureSwipeVelocityY, augmented ? 0 : velocity);
    if (augmented) {
        CGEventSetIntegerValueField(ev, kCGEventGesturePhaseAlias, phase);
        CGEventSetDoubleValueField(ev, kCGEventGestureZoomDeltaY, 3.0);
        CGEventSetDoubleValueField(ev, kCGEventGestureSwipePositionX, 0.1);
        out->dock = strafe_create_augmented_event(ev);
        CFRelease(ev);
        if (!out->dock) { return false; }
        out->companion = CGEventCreate(NULL);
        if (!out->companion) { return false; }
        CGEventSetIntegerValueField(out->companion, kCGSEventTypeField, kCGSEventGesture);
    }
    // Re-serialization may discard userData. Tag only the final objects.
    CGEventSetIntegerValueField(out->dock, kCGEventSourceUserData, kJumpCutSyntheticTag);
    if (CGEventGetIntegerValueField(out->dock, kCGEventSourceUserData) != kJumpCutSyntheticTag) {
        return false;
    }
    if (out->companion) {
        CGEventSetIntegerValueField(out->companion, kCGEventSourceUserData, kJumpCutSyntheticTag);
        if (CGEventGetIntegerValueField(out->companion, kCGEventSourceUserData) != kJumpCutSyntheticTag) {
            return false;
        }
    }
    return true;
}

static void post_phase(const PreparedPhase *phase) {
    CGEventPost(kCGSessionEventTap, phase->dock);
    if (phase->companion) { CGEventPost(kCGSessionEventTap, phase->companion); }
}

void strafe_post_prepared_gesture(StrafePreparedGesture *gesture) {
    if (!gesture) { return; }
    for (uint32_t i = 0; i < gesture->phaseCount; i++) {
        post_phase(&gesture->phases[i]);
        if (gesture->phases[i].delayAfterMicroseconds) {
            usleep(gesture->phases[i].delayAfterMicroseconds);
        }
    }
}

StrafePreparedGesture *strafe_prepare_switch_gesture(StrafeDirection direction, double velocity) {
    if ((direction != StrafeDirectionLeft && direction != StrafeDirectionRight)
        || !isfinite(velocity) || velocity <= 0) { return NULL; }
    const bool augmented = strafe_uses_iohid_payload();
    const bool reversed = augmented && natural_scrolling_enabled();
    const double sign = direction == StrafeDirectionRight ? 1.0 : -1.0;
    // Existing macOS 27 profile from noswoosh's measurements. This preparation
    // guarantee does not establish compositor correctness on any OS build.
    const double progress = sign * (augmented ? 0.1 : (double)FLT_TRUE_MIN);
    const CGSGesturePhase phases[] = {
        kCGSGesturePhaseBegan, kCGSGesturePhaseChanged, kCGSGesturePhaseEnded
    };
    StrafePreparedGesture *gesture = allocate_gesture(3);
    if (!gesture) { return NULL; }
    for (uint32_t i = 0; i < 3; i++) {
        double speed = augmented ? (i == 2 ? sign * 9999.0 : 0.0) : sign * velocity;
        if (!prepare_phase(&gesture->phases[i], phases[i], progress, speed, augmented, reversed)) {
            strafe_free_prepared_gesture(gesture);
            return NULL;
        }
    }
    return gesture;
}

StrafePreparedGesture *strafe_prepare_ramp_gesture(StrafeDirection direction,
    double peakProgress, double endVelocity, uint32_t steps, uint32_t delayMicroseconds) {
    if ((direction != StrafeDirectionLeft && direction != StrafeDirectionRight)
        || !isfinite(peakProgress) || peakProgress <= 0
        || !isfinite(endVelocity) || endVelocity <= 0
        || steps == 0 || steps > UINT32_MAX - 2) { return NULL; }
    const bool augmented = strafe_uses_iohid_payload();
    const bool reversed = augmented && natural_scrolling_enabled();
    const double sign = direction == StrafeDirectionRight ? 1.0 : -1.0;
    StrafePreparedGesture *gesture = allocate_gesture(steps + 2);
    if (!gesture) { return NULL; }
    for (uint32_t i = 0; i < gesture->phaseCount; i++) {
        CGSGesturePhase phase = i == 0 ? kCGSGesturePhaseBegan
            : (i == steps + 1 ? kCGSGesturePhaseEnded : kCGSGesturePhaseChanged);
        double fraction = i == steps + 1 ? 1.0 : (double)i / (double)steps;
        if (!prepare_phase(&gesture->phases[i], phase, sign * peakProgress * fraction,
                           sign * endVelocity * fraction, augmented, reversed)) {
            strafe_free_prepared_gesture(gesture);
            return NULL;
        }
        if (phase == kCGSGesturePhaseChanged) {
            gesture->phases[i].delayAfterMicroseconds = delayMicroseconds;
        }
    }
    return gesture;
}

bool strafe_post_switch_gesture(StrafeDirection direction, double velocity) {
    StrafePreparedGesture *gesture = strafe_prepare_switch_gesture(direction, velocity);
    if (!gesture) { return false; }
    strafe_post_prepared_gesture(gesture);
    strafe_free_prepared_gesture(gesture);
    return true;
}

bool strafe_post_dock_swipe_phase(int64_t phase, double progress, double velocity) {
    const bool augmented = strafe_uses_iohid_payload();
    const bool reversed = augmented && natural_scrolling_enabled();
    PreparedPhase prepared = {0};
    bool success = prepare_phase(&prepared, (CGSGesturePhase)phase,
                                progress, velocity, augmented, reversed);
    if (success) { post_phase(&prepared); }
    free_phase(&prepared);
    return success;
}

#ifdef JUMPCUT_PREPARATION_TESTING
#undef calloc
#undef free
#undef CGEventCreate
#undef CGEventSetIntegerValueField
#undef CFRelease
#undef usleep
#endif

// --- Topology (SPEC §6) ---------------------------------------------------
// A failed or ambiguous cursor lookup is unknown, not the first display.
static CFStringRef copy_cursor_display_identifier(void) {
    CGEventRef locEvent = CGEventCreate(NULL);
    if (!locEvent) { return NULL; }
    CGPoint loc = CGEventGetLocation(locEvent);
    CFRelease(locEvent);

    CGDirectDisplayID displays[16];
    uint32_t matching = 0;
    if (CGGetDisplaysWithPoint(loc, 16, displays, &matching) != kCGErrorSuccess || matching != 1) {
        return NULL;
    }
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displays[0]);
    if (!uuid) { return NULL; }
    CFStringRef str = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return str;
}

static bool valid_display_identifier(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) { return false; }
    CFStringRef string = (CFStringRef)value;
    CFIndex length = CFStringGetLength(string);
    if (length == 0 || length >= (CFIndex)sizeof(((StrafeInfo *)0)->displayID)) { return false; }
    for (CFIndex i = 0; i < length; i++) {
        if (CFStringGetCharacterAtIndex(string, i) == 0) { return false; }
    }
    return true;
}

static bool read_space_id(CFTypeRef value, uint64_t *outID) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() || CFNumberIsFloatType(value)) {
        return false;
    }
    int64_t identifier = 0;
    if (!CFNumberGetValue(value, kCFNumberSInt64Type, &identifier) || identifier <= 0) {
        return false;
    }
    *outID = (uint64_t)identifier;
    return true;
}

// Parse the same private snapshot used by the live query. Never skip malformed
// entries: that would change the meaning of a positional boundary/index.
static bool parse_space_info(CFTypeRef displaysValue, CFTypeRef targetDisplay, StrafeInfo *outInfo) {
    if (!outInfo) { return false; }
    memset(outInfo, 0, sizeof(*outInfo));
    if (!valid_display_identifier(targetDisplay) || !displaysValue ||
        CFGetTypeID(displaysValue) != CFArrayGetTypeID()) { return false; }

    CFArrayRef displays = (CFArrayRef)displaysValue;
    CFDictionaryRef display = NULL;
    CFIndex displayCount = CFArrayGetCount(displays);
    for (CFIndex i = 0; i < displayCount; i++) {
        CFTypeRef candidate = CFArrayGetValueAtIndex(displays, i);
        if (!candidate || CFGetTypeID(candidate) != CFDictionaryGetTypeID()) { return false; }
        CFTypeRef identifier = CFDictionaryGetValue(candidate, CFSTR("Display Identifier"));
        if (!valid_display_identifier(identifier)) { return false; }
        if (CFEqual(identifier, targetDisplay)) {
            if (display) { return false; } // Duplicate identities are ambiguous.
            display = (CFDictionaryRef)candidate;
        }
    }
    if (!display) { return false; }

    CFTypeRef spacesValue = CFDictionaryGetValue(display, CFSTR("Spaces"));
    CFTypeRef activeValue = CFDictionaryGetValue(display, CFSTR("Current Space"));
    if (!spacesValue || CFGetTypeID(spacesValue) != CFArrayGetTypeID() ||
        !activeValue || CFGetTypeID(activeValue) != CFDictionaryGetTypeID()) { return false; }
    CFArrayRef spaces = (CFArrayRef)spacesValue;
    CFIndex count = CFArrayGetCount(spaces);
    if (count <= 0 || count > STRAFE_MAX_SPACES) { return false; }
    uint64_t activeID = 0;
    if (!read_space_id(CFDictionaryGetValue(activeValue, CFSTR("id64")), &activeID)) { return false; }

    StrafeInfo info = {0};
    bool activeFound = false;
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef space = CFArrayGetValueAtIndex(spaces, i);
        if (!space || CFGetTypeID(space) != CFDictionaryGetTypeID() ||
            !read_space_id(CFDictionaryGetValue(space, CFSTR("id64")), &info.spaceIDs[i])) {
            return false;
        }
        for (CFIndex previous = 0; previous < i; previous++) {
            if (info.spaceIDs[previous] == info.spaceIDs[i]) { return false; }
        }
        if (info.spaceIDs[i] == activeID) {
            info.currentIndex = (unsigned int)i;
            activeFound = true;
        }
    }
    if (!activeFound || !CFStringGetCString((CFStringRef)targetDisplay, info.displayID,
                                            sizeof(info.displayID), kCFStringEncodingUTF8)) {
        return false;
    }
    info.spaceCount = (unsigned int)count;
    *outInfo = info;
    return true;
}

#ifdef JUMPCUT_TESTING
// Not present in the app or its public module. Tests supply real CF containers
// to the production parser without consulting or changing the CI desktop.
bool strafe_test_parse_space_info(CFTypeRef displays, CFTypeRef target, StrafeInfo *outInfo) {
    return parse_space_info(displays, target, outInfo);
}
#endif

bool strafe_get_space_info(StrafeInfo *outInfo) {
    if (!outInfo) { return false; }
    memset(outInfo, 0, sizeof(*outInfo));
    if (!strafe_cgs_available()) { return false; }
    CFStringRef targetDisplay = copy_cursor_display_identifier();
    if (!targetDisplay) { return false; }
    CFArrayRef displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID(), NULL);
    bool found = parse_space_info(displays, targetDisplay, outInfo);
    if (displays) { CFRelease(displays); }
    CFRelease(targetDisplay);
    return found;
}

// --- Event inspection helpers (SPEC §2.2, §2.3) ---------------------------
int64_t strafe_event_cgs_type(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGSEventTypeField);
}
int64_t strafe_event_hid_type(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGestureHIDType);
}
int64_t strafe_event_swipe_motion(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGestureSwipeMotion);
}
int64_t strafe_event_gesture_phase(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventGesturePhase);
}
double strafe_event_swipe_progress(CGEventRef event) {
    return CGEventGetDoubleValueField(event, kCGEventGestureSwipeProgress);
}
double strafe_event_swipe_velocity_x(CGEventRef event) {
    return CGEventGetDoubleValueField(event, kCGEventGestureSwipeVelocityX);
}
int64_t strafe_event_source_pid(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
}
bool strafe_event_is_own_synthetic(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kJumpCutSyntheticTag;
}

// Direction of a REAL (pid 0) gesture from the sign of field 124/129: positive
// means the Space on the right, on every macOS version and with Natural
// scrolling on or off (measured on macOS 27.0, 26A428, both settings).
bool strafe_event_moves_right(double progressOrVelocity) {
    return progressOrVelocity > 0;
}

void strafe_clear_swipe_motion(CGEventRef event) {
    CGEventSetDoubleValueField(event, kCGEventGestureSwipeProgress, 0);
    CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityX, 0);
    CGEventSetDoubleValueField(event, kCGEventGestureSwipeVelocityY, 0);
}

// --- Constants (SPEC §1.3) ------------------------------------------------
int64_t strafe_cgs_event_dock_control(void)    { return kCGSEventDockControl; }
int64_t strafe_cgs_event_gesture(void)         { return kCGSEventGesture; }
int64_t strafe_iohid_event_dock_swipe(void)    { return kIOHIDEventTypeDockSwipe; }
int64_t strafe_gesture_motion_horizontal(void) { return kCGGestureMotionHorizontal; }
int64_t strafe_gesture_phase_began(void)       { return kCGSGesturePhaseBegan; }
int64_t strafe_gesture_phase_changed(void)     { return kCGSGesturePhaseChanged; }
int64_t strafe_gesture_phase_ended(void)       { return kCGSGesturePhaseEnded; }
int64_t strafe_gesture_phase_cancelled(void)   { return kCGSGesturePhaseCancelled; }

// --- Private CGEventField indices (SPEC §1.2) -----------------------------
// Value accessors so an out-of-tree caller can build a custom-shaped dock-swipe
// event without re-hardcoding these numbers. No behavior change: the app never
// calls these, and they post nothing. The field indices stay single-sourced in
// the static consts at the top of this file.
int32_t strafe_field_cgs_event_type(void)   { return (int32_t)kCGSEventTypeField; }
int32_t strafe_field_hid_type(void)         { return (int32_t)kCGEventGestureHIDType; }
int32_t strafe_field_swipe_motion(void)     { return (int32_t)kCGEventGestureSwipeMotion; }
int32_t strafe_field_swipe_progress(void)   { return (int32_t)kCGEventGestureSwipeProgress; }
int32_t strafe_field_swipe_velocity_x(void) { return (int32_t)kCGEventGestureSwipeVelocityX; }
int32_t strafe_field_swipe_velocity_y(void) { return (int32_t)kCGEventGestureSwipeVelocityY; }
int32_t strafe_field_gesture_phase(void)    { return (int32_t)kCGEventGesturePhase; }

// Raw tap mask: (1<<29) gesture | (1<<30) dock-control ONLY.
//
// KEY-EVENTS-IN-MASK DETERMINATION (see docs/SPEC.md §2.1):
// The upstream reference (and this file's earlier revision) also OR'd in
// keyDown|keyUp. That was NOT required for correct interception and has been
// removed. Evidence:
//   - The interceptor state machine (SwipeInterceptor.handle) is driven ENTIRELY
//     by dock-control gesture phases (field 132) on CGSEventType 29/30. Nothing
//     in the callback ever inspects a key event: a keyDown/keyUp fails the
//     `cgsType == dockControl || cgsType == gesture` guard on field 55 and is
//     passed straight through, unused. There is no Exposé-via-keys handling, no
//     prediction reset on keys, and no key-driven tap re-enable.
//   - Tap re-enable is handled via the kCGEventTapDisabledByTimeout /
//     ByUserInput callbacks, which the system delivers to the callback
//     REGARDLESS of the event mask — so dropping keys does not affect re-enable.
//   - Global switch hotkeys use Carbon RegisterEventHotKey (HotkeyManager), a
//     separate mechanism that does not depend on this tap seeing key events.
// Cost of the old mask: every keystroke system-wide round-tripped synchronously
// through this process's active tap only to be passed through, adding keyboard
// latency and a wakeup per key. With keys removed the active tap wakes only on
// real space-swipe gestures, dropping idle keyboard wakeups to zero. Behavior is
// unchanged because the removed events were never acted upon.
uint64_t strafe_tap_event_mask(void) {
    return (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
}

// --- Overlay / Exposé detection (SPEC §2.5) -------------------------------
// Heuristic: count Dock-owned windows at layers 18 and 20.
bool strafe_is_expose_active(void) {
    return strafe_is_expose_active_with_diagnostics(NULL);
}

bool strafe_is_expose_active_with_diagnostics(StrafeOverlayDiagnostics *outDiagnostics) {
    StrafeOverlayDiagnostics diagnostics = {0};
    // Do not treat a lone Dock-owned layer-20 window as an overlay. A real
    // macOS 27.2 (26B123) capture observed layer18=0/layer20=1 on the normal
    // desktop for every valid four-finger Space swipe, so that upstream
    // macOS-27 shortcut creates a persistent false positive. Keep the older,
    // more specific layer-18 + layer-20 evidence below.
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) {
        if (outDiagnostics) { *outDiagnostics = diagnostics; }
        return false;
    }
    diagnostics.querySucceeded = true;

    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef win = (CFDictionaryRef)CFArrayGetValueAtIndex(windows, i);
        if (!win) { continue; }

        CFStringRef owner = (CFStringRef)CFDictionaryGetValue(win, kCGWindowOwnerName);
        if (!owner || CFStringCompare(owner, CFSTR("Dock"), 0) != kCFCompareEqualTo) {
            continue;
        }
        CFNumberRef layerNum = (CFNumberRef)CFDictionaryGetValue(win, kCGWindowLayer);
        if (!layerNum) { continue; }
        int layer = 0;
        CFNumberGetValue(layerNum, kCFNumberIntType, &layer);
        if (layer == 18) { diagnostics.layer18Count++; }
        else if (layer == 20) { diagnostics.layer20Count++; }
    }
    CFRelease(windows);
    if (outDiagnostics) { *outDiagnostics = diagnostics; }

    // App Exposé: layer18Count > 0 && layer20Count > 0 && layer20Count <= layer18Count.
    // Mission Control: layer18Count > 0 && layer20Count > layer18Count.
    if (diagnostics.layer18Count > 0 && diagnostics.layer20Count > 0 &&
        diagnostics.layer20Count <= diagnostics.layer18Count) { return true; }
    if (diagnostics.layer18Count > 0 &&
        diagnostics.layer20Count > diagnostics.layer18Count) { return true; }
    return false;
}
