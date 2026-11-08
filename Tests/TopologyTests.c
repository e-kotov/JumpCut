#include "CStrafe.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#ifndef JUMPCUT_TESTING
#error "Topology tests require the test-only parser entry point"
#endif
extern bool strafe_test_parse_space_info(CFTypeRef, CFTypeRef, StrafeInfo *);

static unsigned checks = 0;

static CFMutableDictionaryRef dictionary(void) {
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
}

static CFMutableArrayRef array(void) {
    return CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
}

static CFMutableDictionaryRef space(int64_t identifier) {
    CFMutableDictionaryRef result = dictionary();
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &identifier);
    CFDictionarySetValue(result, CFSTR("id64"), number);
    CFRelease(number);
    return result;
}

static CFMutableDictionaryRef display(CFStringRef identifier, const int64_t *ids,
                                       CFIndex count, int64_t activeID) {
    CFMutableDictionaryRef result = dictionary();
    CFMutableArrayRef spaces = array();
    for (CFIndex i = 0; i < count; i++) {
        CFMutableDictionaryRef item = space(ids[i]);
        // Fullscreen Spaces are retained at their actual ordered position.
        int type = i == 1 ? 4 : 0;
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &type);
        CFDictionarySetValue(item, CFSTR("type"), number);
        CFRelease(number);
        CFArrayAppendValue(spaces, item);
        CFRelease(item);
    }
    CFMutableDictionaryRef active = space(activeID);
    CFDictionarySetValue(result, CFSTR("Display Identifier"), identifier);
    CFDictionarySetValue(result, CFSTR("Spaces"), spaces);
    CFDictionarySetValue(result, CFSTR("Current Space"), active);
    CFRelease(spaces);
    CFRelease(active);
    return result;
}

static void invalid(CFTypeRef displays, CFTypeRef target) {
    StrafeInfo info;
    memset(&info, 0xA5, sizeof(info));
    assert(!strafe_test_parse_space_info(displays, target, &info));
    StrafeInfo empty = {0};
    assert(memcmp(&info, &empty, sizeof(info)) == 0);
    checks++;
}

static StrafeInfo valid(CFTypeRef displays, CFStringRef target, unsigned index,
                        const int64_t *ids, unsigned count) {
    StrafeInfo info;
    assert(strafe_test_parse_space_info(displays, target, &info));
    assert(info.currentIndex == index && info.spaceCount == count);
    char identifier[128];
    assert(CFStringGetCString(target, identifier, sizeof(identifier), kCFStringEncodingUTF8));
    assert(strcmp(info.displayID, identifier) == 0);
    for (unsigned i = 0; i < count; i++) { assert(info.spaceIDs[i] == (uint64_t)ids[i]); }
    checks++;
    return info;
}

static void test_identity_and_order(void) {
    const int64_t firstIDs[] = {11, 12, 13};
    const int64_t secondIDs[] = {21, 22, 23};
    CFMutableDictionaryRef first = display(CFSTR("first"), firstIDs, 3, 13);
    CFMutableDictionaryRef second = display(CFSTR("second"), secondIDs, 3, 21);
    CFMutableArrayRef displays = array();
    CFArrayAppendValue(displays, first);
    CFArrayAppendValue(displays, second);
    valid(displays, CFSTR("first"), 2, firstIDs, 3);
    valid(displays, CFSTR("second"), 0, secondIDs, 3);
    invalid(displays, NULL);
    invalid(displays, CFSTR("missing"));
    invalid(displays, kCFBooleanTrue);

    CFArrayAppendValue(displays, second);
    invalid(displays, CFSTR("second"));
    CFArrayRemoveValueAtIndex(displays, 2);

    const int64_t reordered[] = {21, 23, 22};
    CFMutableDictionaryRef changed = display(CFSTR("second"), reordered, 3, 22);
    CFArraySetValueAtIndex(displays, 1, changed);
    StrafeInfo reorderedInfo = valid(displays, CFSTR("second"), 2, reordered, 3);
    CFRelease(changed);
    const int64_t replaced[] = {21, 24, 22};
    changed = display(CFSTR("second"), replaced, 3, 22);
    CFArraySetValueAtIndex(displays, 1, changed);
    StrafeInfo replacedInfo = valid(displays, CFSTR("second"), 2, replaced, 3);
    assert(reorderedInfo.spaceIDs[1] != replacedInfo.spaceIDs[1]);
    CFRelease(changed);
    CFRelease(displays);
    CFRelease(second);
    CFRelease(first);
}

static void test_malformed_containers(void) {
    const int64_t ids[] = {11, 12, 13};
    CFMutableDictionaryRef item = display(CFSTR("screen"), ids, 3, 12);
    CFMutableArrayRef displays = array();
    invalid(NULL, CFSTR("screen"));
    invalid(kCFBooleanTrue, CFSTR("screen"));
    invalid(item, CFSTR("screen"));
    invalid(displays, CFSTR("screen"));
    CFArrayAppendValue(displays, CFSTR("not a display"));
    invalid(displays, CFSTR("screen"));
    CFArraySetValueAtIndex(displays, 0, item);

    const CFStringRef keys[] = {CFSTR("Display Identifier"), CFSTR("Spaces"), CFSTR("Current Space")};
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CFTypeRef saved = CFRetain(CFDictionaryGetValue(item, keys[i]));
        CFDictionaryRemoveValue(item, keys[i]);
        invalid(displays, CFSTR("screen"));
        CFDictionarySetValue(item, keys[i], kCFBooleanFalse);
        invalid(displays, CFSTR("screen"));
        CFDictionarySetValue(item, keys[i], saved);
        CFRelease(saved);
    }
    CFMutableArrayRef spaces = (CFMutableArrayRef)CFDictionaryGetValue(item, CFSTR("Spaces"));
    CFTypeRef saved = CFRetain(CFArrayGetValueAtIndex(spaces, 1));
    CFArraySetValueAtIndex(spaces, 1, CFSTR("not a space"));
    invalid(displays, CFSTR("screen"));
    CFArraySetValueAtIndex(spaces, 1, saved);
    CFRelease(saved);

    CFMutableDictionaryRef active = (CFMutableDictionaryRef)CFDictionaryGetValue(item, CFSTR("Current Space"));
    CFDictionaryRemoveValue(active, CFSTR("id64"));
    invalid(displays, CFSTR("screen"));
    assert(!strafe_test_parse_space_info(displays, CFSTR("screen"), NULL));
    checks++;
    CFRelease(displays);
    CFRelease(item);
}

static void test_invalid_ids(void) {
    const int64_t ids[] = {11, 12, 13};
    CFMutableArrayRef displays = array();
    CFMutableDictionaryRef item = display(CFSTR("screen"), ids, 3, 99);
    CFArrayAppendValue(displays, item);
    invalid(displays, CFSTR("screen")); // Unknown active Space is not index zero.
    CFRelease(item);

    item = display(CFSTR("screen"), ids, 3, 12);
    CFArraySetValueAtIndex(displays, 0, item);
    CFMutableArrayRef spaces = (CFMutableArrayRef)CFDictionaryGetValue(item, CFSTR("Spaces"));
    CFMutableDictionaryRef middle = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(spaces, 1);
    CFMutableDictionaryRef active = (CFMutableDictionaryRef)CFDictionaryGetValue(item, CFSTR("Current Space"));
    const int64_t badIntegers[] = {0, -1, 11};
    for (unsigned i = 0; i < sizeof(badIntegers) / sizeof(badIntegers[0]); i++) {
        CFNumberRef bad = CFNumberCreate(NULL, kCFNumberSInt64Type, &badIntegers[i]);
        CFDictionarySetValue(middle, CFSTR("id64"), bad);
        invalid(displays, CFSTR("screen")); // Also rejects duplicate IDs.
        CFRelease(bad);
    }
    double fraction = 12.5;
    CFNumberRef floating = CFNumberCreate(NULL, kCFNumberDoubleType, &fraction);
    const CFTypeRef invalidValues[] = {CFSTR("12"), kCFBooleanTrue, floating};
    for (unsigned i = 0; i < sizeof(invalidValues) / sizeof(invalidValues[0]); i++) {
        CFDictionarySetValue(middle, CFSTR("id64"), invalidValues[i]);
        invalid(displays, CFSTR("screen"));
    }
    CFNumberRef twelve = CFNumberCreate(NULL, kCFNumberSInt64Type, &ids[1]);
    CFDictionarySetValue(middle, CFSTR("id64"), twelve);
    CFRelease(twelve);
    for (unsigned i = 0; i < sizeof(invalidValues) / sizeof(invalidValues[0]); i++) {
        CFDictionarySetValue(active, CFSTR("id64"), invalidValues[i]);
        invalid(displays, CFSTR("screen"));
    }
    CFRelease(floating);
    CFRelease(displays);
    CFRelease(item);
}

static void test_bounds_and_strings(void) {
    int64_t ids[STRAFE_MAX_SPACES + 1];
    for (unsigned i = 0; i < STRAFE_MAX_SPACES + 1; i++) { ids[i] = i + 1; }
    CFMutableArrayRef displays = array();
    CFMutableDictionaryRef item = display(CFSTR("screen"), ids, STRAFE_MAX_SPACES, STRAFE_MAX_SPACES);
    CFArrayAppendValue(displays, item);
    valid(displays, CFSTR("screen"), STRAFE_MAX_SPACES - 1, ids, STRAFE_MAX_SPACES);
    CFRelease(item);
    item = display(CFSTR("screen"), ids, STRAFE_MAX_SPACES + 1, 1);
    CFArraySetValueAtIndex(displays, 0, item);
    invalid(displays, CFSTR("screen"));
    CFRelease(item);
    item = display(CFSTR("screen"), ids, 0, 1);
    CFArraySetValueAtIndex(displays, 0, item);
    invalid(displays, CFSTR("screen"));
    CFRelease(item);

    UniChar wide[100];
    for (unsigned i = 0; i < 100; i++) { wide[i] = 0x00E9; }
    CFStringRef tooManyBytes = CFStringCreateWithCharacters(NULL, wide, 100);
    const UniChar nulChars[] = {'a', 0, 'b'};
    CFStringRef embeddedNul = CFStringCreateWithCharacters(NULL, nulChars, 3);
    const CFStringRef invalidNames[] = {CFSTR(""), tooManyBytes, embeddedNul};
    for (unsigned i = 0; i < sizeof(invalidNames) / sizeof(invalidNames[0]); i++) {
        item = display(invalidNames[i], ids, 2, 1);
        CFArraySetValueAtIndex(displays, 0, item);
        invalid(displays, invalidNames[i]);
        CFRelease(item);
    }
    CFRelease(tooManyBytes);
    CFRelease(embeddedNul);
    CFRelease(displays);
}

int main(void) {
    test_identity_and_order();
    test_malformed_containers();
    test_invalid_ids();
    test_bounds_and_strings();
    printf("Topology parser: %u checks passed (no desktop queries or posting).\n", checks);
    return 0;
}
