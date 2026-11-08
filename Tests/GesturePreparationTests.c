#include "CStrafe.h"
#include "PreparationTestHooks.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// Wrappers return actual CoreGraphics objects and inject preparation failures.
// OS/preferences, sleeping and event posting are controlled by the fixture.
// Every acquired reference/buffer is tracked, including serialization temporaries.
static const void *owned[256];
static unsigned ownedCount;
static unsigned allocationAttempts;
static unsigned failAt;
static unsigned tagWrites;
static unsigned failTagAt;
static unsigned serializations;
static unsigned corruptSerialization;
static bool modern;
static bool natural;
static bool changeSettingsDuringPreparation;
static unsigned osReads;
static unsigned preferenceReads;
static CGEventRef posted[64];
static unsigned postedCount;
static unsigned sleepCount;
static uint64_t totalSleep;
static bool fail_allocation(void) {
    allocationAttempts++;
    if (changeSettingsDuringPreparation) { modern = !modern; natural = !natural; }
    return allocationAttempts == failAt;
}

static void remember(const void *pointer) {
    assert(pointer && ownedCount < sizeof(owned) / sizeof(owned[0]));
    for (unsigned i = 0; i < ownedCount; i++) { assert(owned[i] != pointer); }
    owned[ownedCount++] = pointer;
}

static void forget(const void *pointer) {
    assert(pointer);
    for (unsigned i = 0; i < ownedCount; i++) {
        if (owned[i] == pointer) {
            owned[i] = owned[--ownedCount];
            return;
        }
    }
    assert(!"release of an unowned or already released preparation resource");
}

bool strafe_test_uses_iohid_payload(void) { osReads++; return modern; }
bool strafe_test_natural_scrolling_enabled(void) { preferenceReads++; return natural; }

void *strafe_test_calloc(size_t count, size_t size) {
    if (fail_allocation()) { return NULL; }
    void *pointer = calloc(count, size);
    assert(pointer);
    remember(pointer);
    return pointer;
}

void *strafe_test_malloc(size_t size) {
    if (fail_allocation()) { return NULL; }
    void *pointer = malloc(size);
    assert(pointer);
    remember(pointer);
    return pointer;
}

void strafe_test_free(void *pointer) {
    if (pointer) { forget(pointer); free(pointer); }
}

CGEventRef strafe_test_event_create(CGEventSourceRef source) {
    if (fail_allocation()) { return NULL; }
    CGEventRef event = CGEventCreate(source);
    assert(event);
    remember(event);
    return event;
}

void strafe_test_set_integer(CGEventRef event, CGEventField field, int64_t value) {
    // A void setter can silently reject a tag. The real preparation path must
    // verify readback before any part of the sequence is submitted.
    if (field == kCGEventSourceUserData && value == 0x4A554D50) {
        if (++tagWrites == failTagAt) { return; }
    }
    CGEventSetIntegerValueField(event, field, value);
}

CFDataRef strafe_test_event_create_data(CFAllocatorRef allocator, CGEventRef event) {
    if (fail_allocation()) { return NULL; }
    // Tags must be applied after the serialization step, not relied on to
    // survive it. Leave reconstructed source fields untouched: on the macOS
    // 26.7.2 diagnostic runner, writing zero to rebuilt userData prevented later
    // tag writes from taking effect, while untouched reconstruction worked.
    assert(CGEventGetIntegerValueField(event, kCGEventSourceUserData) == 0);
    CFDataRef data = CGEventCreateData(allocator, event);
    assert(data);
    if (++serializations == corruptSerialization) {
        CFMutableDataRef corrupt = CFDataCreateMutableCopy(NULL, 0, data);
        assert(corrupt && CFDataGetLength(corrupt) >= 4);
        CFDataGetMutableBytePtr(corrupt)[3] = 99;
        CFRelease(data);
        data = corrupt;
    }
    remember(data);
    return data;
}

CFDataRef strafe_test_data_create(CFAllocatorRef allocator, const UInt8 *bytes, CFIndex length) {
    if (fail_allocation()) { return NULL; }
    CFDataRef data = CFDataCreate(allocator, bytes, length);
    assert(data);
    remember(data);
    return data;
}

CGEventRef strafe_test_event_from_data(CFAllocatorRef allocator, CFDataRef data) {
    if (fail_allocation()) { return NULL; }
    CGEventRef event = CGEventCreateFromData(allocator, data);
    assert(event);
    remember(event);
    return event;
}

void strafe_test_release(CFTypeRef object) {
    forget(object);
    CFRelease(object);
}

int strafe_test_usleep(useconds_t delay) {
    sleepCount++;
    totalSleep += delay;
    return 0;
}

// Interpose the actual posting entry point. These tests never create a system
// event tap, need Accessibility permission, or deliver input to the desktop.
void CGEventPost(CGEventTapLocation location, CGEventRef event) {
    assert(location == kCGSessionEventTap);
    assert(event && postedCount < sizeof(posted) / sizeof(posted[0]));
    assert(CGEventGetIntegerValueField(event, kCGEventSourceUserData) == 0x4A554D50);
    posted[postedCount++] = (CGEventRef)CFRetain(event);
}

static void reset(bool useModern, bool useNatural) {
    assert(ownedCount == 0);
    for (unsigned i = 0; i < postedCount; i++) { CFRelease(posted[i]); }
    postedCount = allocationAttempts = failAt = serializations = corruptSerialization = 0;
    tagWrites = failTagAt = 0;
    osReads = preferenceReads = sleepCount = 0;
    totalSleep = 0;
    modern = useModern;
    natural = useNatural;
    changeSettingsDuringPreparation = false;
}

static uint32_t read32(const uint8_t *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof(value));
    return value;
}

static void check_payload(CGEventRef event, int phase, double progress, double velocity) {
    CFDataRef serialized = CGEventCreateData(NULL, event);
    assert(serialized);
    const uint8_t *bytes = CFDataGetBytePtr(serialized);
    size_t length = (size_t)CFDataGetLength(serialized);
    unsigned found = 0;
    for (size_t offset = 4; offset + 4 <= length; offset++) {
        size_t size = ((size_t)bytes[offset] << 8) | bytes[offset + 1];
        unsigned field = ((unsigned)bytes[offset + 2] << 8) | bytes[offset + 3];
        if (field != 4205 || (size != 68 && size != 96)) { continue; }
        assert(offset + 4 + size <= length);
        const uint8_t *payload = bytes + offset + 4;
        bool hasVelocity = velocity != 0 || phase == 4;
        assert(size == (hasVelocity ? 96 : 68));
        assert(read32(payload + 24) == (hasVelocity ? 2 : 1));
        assert(read32(payload + 28) == 40);
        assert(read32(payload + 32) == 23);
        assert(read32(payload + 36) == (uint32_t)phase << 24);
        assert(read32(payload + 44) == (uint32_t)(0.1 * 65536));
        assert(payload[60] == 1 && payload[62] == 3);
        assert((int32_t)read32(payload + 64) == (int32_t)(progress * 65536));
        if (hasVelocity) {
            assert(read32(payload + 68) == 28 && read32(payload + 72) == 9);
            assert(payload[80] == 1);
            assert((int32_t)read32(payload + 84) == (int32_t)(velocity * 65536));
            assert(read32(payload + 88) == 0);
        }
        found++;
    }
    assert(found == 1);
    CFRelease(serialized);
}

static void check_phase(unsigned index, bool useModern, int phase,
                        double progress, double velocity) {
    unsigned stride = useModern ? 2 : 1;
    CGEventRef event = posted[index * stride];
    assert(CGEventGetType(event) == 30);
    assert(CGEventGetIntegerValueField(event, 110) == 23);
    assert(CGEventGetIntegerValueField(event, 123) == 1);
    assert(CGEventGetIntegerValueField(event, 132) == phase);
    assert(fabs(CGEventGetDoubleValueField(event, 124) - progress) < 1e-7);
    assert(fabs(CGEventGetDoubleValueField(event, 129) - velocity) < 1e-7);
    assert(CGEventGetDoubleValueField(event, 130) == (useModern ? 0 : velocity));
    assert(CGEventGetIntegerValueField(event, kCGEventSourceUserData) == 0x4A554D50);
    if (useModern) {
        assert(CGEventGetIntegerValueField(event, 134) == phase);
        assert(CGEventGetDoubleValueField(event, 138) == 3);
        assert(fabs(CGEventGetDoubleValueField(event, 125) - 0.1) < 1e-7);
        check_payload(event, phase, progress, velocity);
        CGEventRef companion = posted[index * stride + 1];
        assert(CGEventGetType(companion) == 29);
        assert(CGEventGetIntegerValueField(companion, kCGEventSourceUserData) == 0x4A554D50);
    }
}

static StrafePreparedGesture *prepare(bool ramp, StrafeDirection direction) {
    return ramp
        ? strafe_prepare_ramp_gesture(direction, 0.35, 130, 8, 3750)
        : strafe_prepare_switch_gesture(direction, 2000);
}

static void check_sequence(bool useModern, bool useNatural, StrafeDirection direction, bool ramp) {
    reset(useModern, useNatural);
    changeSettingsDuringPreparation = true;
    StrafePreparedGesture *gesture = prepare(ramp, direction);
    assert(gesture && postedCount == 0 && sleepCount == 0);
    assert(osReads == 1 && preferenceReads == (useModern ? 1U : 0U));
    unsigned attempts = allocationAttempts;
    // Alter both capability and preference again after preparation. Posting
    // must use the prepared convention and do no new allocations or sampling.
    modern = !useModern;
    natural = !useNatural;
    strafe_post_prepared_gesture(gesture);
    assert(allocationAttempts == attempts);
    assert(osReads == 1 && preferenceReads == (useModern ? 1U : 0U));
    strafe_free_prepared_gesture(gesture);
    assert(ownedCount == 0);
    unsigned phases = ramp ? 10 : 3;
    assert(postedCount == phases * (useModern ? 2U : 1U));
    double sign = direction == StrafeDirectionRight ? 1.0 : -1.0;
    if (useModern && useNatural) { sign = -sign; }
    if (ramp) {
        check_phase(0, useModern, 1, 0, 0);
        for (unsigned i = 1; i <= 8; i++) {
            double fraction = (double)i / 8;
            check_phase(i, useModern, 2, sign * 0.35 * fraction, sign * 130 * fraction);
        }
        check_phase(9, useModern, 4, sign * 0.35, sign * 130);
        assert(sleepCount == 8 && totalSleep == 30000);
    } else {
        double progress = sign * (useModern ? 0.1 : (double)FLT_TRUE_MIN);
        check_phase(0, useModern, 1, progress, useModern ? 0 : sign * 2000);
        check_phase(1, useModern, 2, progress, useModern ? 0 : sign * 2000);
        check_phase(2, useModern, 4, progress, sign * (useModern ? 9999 : 2000));
        if (!useModern) {
            // A loose float tolerance alone would incorrectly accept zero or
            // reversed subnormal progress on the pre-27 path.
            for (unsigned i = 0; i < 3; i++) {
                assert(CGEventGetDoubleValueField(posted[i], 124) * sign > 0);
            }
        }
        assert(sleepCount == 0);
    }
}

static void check_failures(bool useModern, bool useNatural, StrafeDirection direction, bool ramp) {
    reset(useModern, useNatural);
    StrafePreparedGesture *gesture = prepare(ramp, direction);
    assert(gesture && postedCount == 0);
    unsigned attempts = allocationAttempts;
    strafe_free_prepared_gesture(gesture); // Discard without posting is valid.
    assert(ownedCount == 0 && postedCount == 0);
    // Includes the sequence storage, each Dock event, serialization CFData,
    // both IOHID buffers, augmented CFData, event reconstruction and companion.
    assert(attempts == 1 + (ramp ? 10U : 3U) * (useModern ? 7U : 1U));
    for (unsigned failed = 1; failed <= attempts; failed++) {
        reset(useModern, useNatural);
        failAt = failed;
        assert(prepare(ramp, direction) == NULL);
        assert(allocationAttempts == failed);
        assert(ownedCount == 0 && postedCount == 0 && sleepCount == 0);
    }
    unsigned tags = (ramp ? 10U : 3U) * (useModern ? 2U : 1U);
    for (unsigned failedTag = 1; failedTag <= tags; failedTag++) {
        reset(useModern, useNatural);
        failTagAt = failedTag;
        assert(prepare(ramp, direction) == NULL);
        assert(tagWrites == failedTag);
        assert(ownedCount == 0 && postedCount == 0 && sleepCount == 0);
    }
    if (useModern) {
        for (unsigned phase = 1; phase <= (ramp ? 10U : 3U); phase++) {
            reset(useModern, useNatural);
            corruptSerialization = phase;
            assert(prepare(ramp, direction) == NULL);
            assert(serializations == phase);
            assert(ownedCount == 0 && postedCount == 0 && sleepCount == 0);
        }
    }
}

static void check_convenience_entry_points(void) {
    // Failure of the final companion must also leave the legacy instant
    // convenience entry point with zero posted events.
    reset(true, true);
    failAt = 22;
    assert(!strafe_post_switch_gesture(StrafeDirectionRight, 2000));
    assert(postedCount == 0 && ownedCount == 0);
    reset(true, false);
    assert(strafe_post_switch_gesture(StrafeDirectionLeft, 2000));
    assert(postedCount == 6 && ownedCount == 0);
    check_phase(2, true, 4, -0.1, -9999);

    reset(true, true);
    failAt = 7;
    assert(!strafe_post_dock_swipe_phase(4, 0.35, 130));
    assert(postedCount == 0 && ownedCount == 0);
    reset(true, true);
    assert(strafe_post_dock_swipe_phase(4, 0.35, 130));
    assert(postedCount == 2 && ownedCount == 0);
    check_phase(0, true, 4, -0.35, -130);
}

int main(void) {
    for (unsigned useModern = 0; useModern < 2; useModern++) {
        for (unsigned useNatural = 0; useNatural < 2; useNatural++) {
            for (unsigned right = 0; right < 2; right++) {
                StrafeDirection direction = right ? StrafeDirectionRight : StrafeDirectionLeft;
                for (unsigned ramp = 0; ramp < 2; ramp++) {
                    check_sequence(useModern, useNatural, direction, ramp);
                    check_failures(useModern, useNatural, direction, ramp);
                }
            }
        }
    }
    check_convenience_entry_points();
    reset(false, false);
    assert(strafe_prepare_switch_gesture((StrafeDirection)99, 2000) == NULL);
    assert(strafe_prepare_switch_gesture(StrafeDirectionRight, NAN) == NULL);
    assert(strafe_prepare_ramp_gesture(StrafeDirectionLeft, 0.35, 130, 0, 100) == NULL);
    assert(strafe_prepare_ramp_gesture(StrafeDirectionLeft, 0.35, 130, UINT32_MAX, 100) == NULL);
    strafe_free_prepared_gesture(NULL);
    assert(ownedCount == 0 && postedCount == 0);
    puts("Gesture preparation: 16 OS/preference/direction/shape cases and every preparation failure passed (no desktop events)");
}
