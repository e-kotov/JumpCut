// Private fault-injection entry points. Only the preparation test executable
// defines these; normal SwiftPM builds contain no test hooks or runtime knobs.
#ifndef JUMPCUT_PREPARATION_TEST_HOOKS_H
#define JUMPCUT_PREPARATION_TEST_HOOKS_H

#ifdef JUMPCUT_PREPARATION_TESTING
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <unistd.h>

bool strafe_test_uses_iohid_payload(void);
bool strafe_test_natural_scrolling_enabled(void);
void *strafe_test_calloc(size_t count, size_t size);
void *strafe_test_malloc(size_t size);
void strafe_test_free(void *pointer);
CGEventRef strafe_test_event_create(CGEventSourceRef source);
void strafe_test_set_integer(CGEventRef event, CGEventField field, int64_t value);
CFDataRef strafe_test_event_create_data(CFAllocatorRef allocator, CGEventRef event);
CFDataRef strafe_test_data_create(CFAllocatorRef allocator, const UInt8 *bytes, CFIndex length);
CGEventRef strafe_test_event_from_data(CFAllocatorRef allocator, CFDataRef data);
void strafe_test_release(CFTypeRef object);
int strafe_test_usleep(useconds_t delay);
#endif

#endif
