// CStrafe.h — low-level CoreGraphics gesture synthesis + inspection shim.
//
// This C target owns every undocumented magic number and private CGS symbol so
// the Swift side never has to touch @_silgen_name or raw CGEventField indices.
// The mechanism is an independent reimplementation of the technique from
// jurplel/InstantSpaceSwitcher (MIT); see docs/SPEC.md for the field-by-field
// derivation.

#ifndef CSTRAFE_H
#define CSTRAFE_H

#include <stdbool.h>
#include <stdint.h>
#include <ApplicationServices/ApplicationServices.h>

#ifdef __cplusplus
extern "C" {
#endif

// Direction of a single-step space switch.
typedef enum {
    StrafeDirectionLeft  = 0,  // previous space
    StrafeDirectionRight = 1,  // next space
} StrafeDirection;

// Topology for one display, filled by strafe_get_space_info(). Larger or
// malformed private responses are unavailable, so native swipes can pass through.
#define STRAFE_MAX_SPACES 128
typedef struct {
    unsigned int currentIndex;   // zero-based index of the active space on this display
    unsigned int spaceCount;     // number of spaces on this display
    char displayID[128];         // display UUID string, used as the prediction-dictionary key
    uint64_t spaceIDs[STRAFE_MAX_SPACES]; // ordered IDs, including fullscreen Spaces
} StrafeInfo;

// --- Capability check (SPEC §1.1, §6) -------------------------------------
// True iff the weak-imported CGS symbols resolved at load time. When false,
// topology can't be read. The interceptor leaves native swipes alone.
bool strafe_cgs_available(void);

// Runtime OS capability; macOS 27 requires augmented synthetic gestures.
bool strafe_uses_iohid_payload(void);
// True when posted horizontal progress/velocity must be negated: macOS 27 with
// Natural scrolling on. Incoming real gestures are never reversed.
bool strafe_posted_sign_reversed(void);
bool strafe_event_moves_right(double progressOrVelocity);
void strafe_clear_swipe_motion(CGEventRef event);

// --- Synthesis (SPEC §1.4, §1.5) ------------------------------------------
// A complete gesture owns all its events (including macOS 27 companions).
// Preparation samples the OS/direction convention once and posts nothing.
// NULL means preparation failed; every partially prepared object was released.
typedef struct StrafePreparedGesture StrafePreparedGesture;
StrafePreparedGesture *strafe_prepare_switch_gesture(StrafeDirection direction, double velocity);
StrafePreparedGesture *strafe_prepare_ramp_gesture(StrafeDirection direction,
    double peakProgress, double endVelocity, uint32_t steps, uint32_t delayMicroseconds);

// Post the whole prepared gesture synchronously, with no further preparation.
// The caller must serialize complete gestures, including mixed speed presets.
// CGEventPost provides no acknowledgement that the Dock accepted a switch.
// Free after posting, or free without posting to discard a prepared gesture.
void strafe_post_prepared_gesture(StrafePreparedGesture *gesture);
void strafe_free_prepared_gesture(StrafePreparedGesture *gesture);

// Convenience: prepare, post and free one instant began -> changed -> ended
// sequence. False means nothing was posted. `velocity` is a positive magnitude
// (default 2000.0); macOS 27 uses its existing 0.1 / 9999 instant profile.
bool strafe_post_switch_gesture(StrafeDirection direction, double velocity);

// Post ONE phase of a horizontal dock swipe with an explicit progress and
// velocity. Retained for the standalone benchmark's custom shapes; the app
// uses complete prepared gestures. Failure posts nothing for this phase, but
// this API makes no guarantee about a sequence assembled by its caller.
bool strafe_post_dock_swipe_phase(int64_t phase, double progress, double velocity);

// --- Topology (SPEC §6) ---------------------------------------------------
// Fill `outInfo` for the display under the cursor. Returns false if the CGS
// symbols are unavailable or topology could not be read.
bool strafe_get_space_info(StrafeInfo *outInfo);

// --- Event inspection helpers for the interceptor (SPEC §2.2, §2.3) -------
// These wrap CGEventGet*ValueField with the private field indices so the Swift
// interceptor never hard-codes a magic number.
int64_t strafe_event_cgs_type(CGEventRef event);      // field 55  -> CGSEventType
int64_t strafe_event_hid_type(CGEventRef event);      // field 110 -> IOHIDEventType
int64_t strafe_event_swipe_motion(CGEventRef event);  // field 123 -> motion axis
int64_t strafe_event_gesture_phase(CGEventRef event); // field 132 -> CGSGesturePhase
double  strafe_event_swipe_progress(CGEventRef event);// field 124 -> progress (double)
double  strafe_event_swipe_velocity_x(CGEventRef event); // field 129 -> velocityX (double)
int64_t strafe_event_source_pid(CGEventRef event);    // kCGEventSourceUnixProcessID
bool strafe_event_is_own_synthetic(CGEventRef event); // explicit marker

// --- Constants the interceptor compares against (SPEC §1.3) ---------------
// Exposed as functions to keep the enum values single-sourced in C.
int64_t strafe_cgs_event_dock_control(void);    // 30
int64_t strafe_cgs_event_gesture(void);         // 29
int64_t strafe_iohid_event_dock_swipe(void);    // 23
int64_t strafe_gesture_motion_horizontal(void); // 1
int64_t strafe_gesture_phase_began(void);       // 1
int64_t strafe_gesture_phase_changed(void);     // 2
int64_t strafe_gesture_phase_ended(void);       // 4
int64_t strafe_gesture_phase_cancelled(void);   // 8

// --- Private CGEventField indices (SPEC §1.2) -----------------------------
// Exposed as functions ONLY so an out-of-tree caller (the bench measurement
// tool) can build a custom-shaped dock-swipe event without re-hardcoding the
// magic field numbers. The strafe app itself does not call these — its posters
// (`strafe_post_switch_gesture`, `strafe_post_dock_swipe_phase`) write the
// fields directly. These are pure value accessors: no behavior change, no new
// event is posted, nothing in the app's code path reads them. The field numbers
// stay single-sourced in CStrafe.c. See docs/SPEC.md §1.2.
int32_t strafe_field_cgs_event_type(void);    // 55  -> CGSEventType selector
int32_t strafe_field_hid_type(void);          // 110 -> IOHIDEvent gesture type
int32_t strafe_field_swipe_motion(void);      // 123 -> motion axis
int32_t strafe_field_swipe_progress(void);    // 124 -> progress (double)
int32_t strafe_field_swipe_velocity_x(void);  // 129 -> velocityX (double)
int32_t strafe_field_swipe_velocity_y(void);  // 130 -> velocityY (double)
int32_t strafe_field_gesture_phase(void);     // 132 -> CGSGesturePhase

// Raw event mask the tap must register: the two private gesture types by raw
// bit shift (1<<29)|(1<<30). Key events are deliberately NOT masked — see the
// KEY-EVENTS-IN-MASK DETERMINATION at the definition in CStrafe.c.
uint64_t strafe_tap_event_mask(void);

// --- Overlay / Exposé passthrough (SPEC §2.5) -----------------------------
// True when App Exposé or Mission Control is up (Dock windows at layers 18/20).
bool strafe_is_expose_active(void);

typedef struct {
    bool querySucceeded;
    bool usesLoneLayer20Rule; // Retained for diagnostics; false since lone layer-20 is not sufficient.
    uint32_t layer18Count;
    uint32_t layer20Count;
} StrafeOverlayDiagnostics;

// The same decision, with optional counts from the single window query used
// to make it. A failed query reports querySucceeded=false and zero counts.
bool strafe_is_expose_active_with_diagnostics(StrafeOverlayDiagnostics *outDiagnostics);

#ifdef __cplusplus
}
#endif

#endif /* CSTRAFE_H */
