// This file exists purely because xcode doesn't like header only targets, SPM is fine with them
#import "private.h"
#import <dlfcn.h>
#import <string.h>

// The same approach is used by yabai
typedef CGError (*SetFrontProcessWithOptionsFn)(ProcessSerialNumber *psn, uint32_t windowId, uint32_t mode);
typedef CGError (*PostEventRecordToFn)(ProcessSerialNumber *psn, uint8_t *bytes);
static const uint32_t kCPSUserGenerated = 0x200;

bool aerospaceMakeWindowKeyAndFront(pid_t pid, uint32_t windowId) {
    static SetFrontProcessWithOptionsFn setFrontProcessWithOptions = NULL;
    static PostEventRecordToFn postEventRecordTo = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (skyLight == NULL) return;
        setFrontProcessWithOptions = (SetFrontProcessWithOptionsFn)dlsym(skyLight, "_SLPSSetFrontProcessWithOptions");
        postEventRecordTo = (PostEventRecordToFn)dlsym(skyLight, "SLPSPostEventRecordTo");
    });
    if (setFrontProcessWithOptions == NULL || postEventRecordTo == NULL) return false;

    ProcessSerialNumber psn = {0};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(pid, &psn) != noErr) return false;
#pragma clang diagnostic pop

    if (setFrontProcessWithOptions(&psn, windowId, kCPSUserGenerated) != kCGErrorSuccess) return false;

    // Synthetic "make key window" event records
    uint8_t bytes[0xf8] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memset(bytes + 0x20, 0xff, 0x10);
    memcpy(bytes + 0x3c, &windowId, sizeof(uint32_t));
    bytes[0x08] = 0x01;
    postEventRecordTo(&psn, bytes);
    bytes[0x08] = 0x02;
    postEventRecordTo(&psn, bytes);
    return true;
}
