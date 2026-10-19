#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdlib.h>
#import <substrate.h>
#import <float.h>
#import <math.h>

#import "VCAudioSampleConverter.h"
#import "VCFrameConverter.h"
#import "VCPreferences.h"
#import "VCSharedMediaBus.h"
#import "VCSharedMediaProtocol.h"
#import "VCStreamCoordinator.h"

typedef void (*VCEmitSampleBufferFunction)(id, SEL, CMSampleBufferRef);
typedef void (*VCVolumeButtonFunction)(id, SEL);
typedef void (*VCVolumeIntegerFunction)(id, SEL, long long);
typedef void (*VCVolumeFloatFunction)(id, SEL, float);
typedef void (*VCVolumeDoubleFunction)(id, SEL, double);
typedef enum {
    VCVolumeHookKindDirectionalNoArgument = 1,
    VCVolumeHookKindDirectionalInteger = 2,
    VCVolumeHookKindDeltaFloat = 3,
    VCVolumeHookKindDeltaDouble = 4,
} VCVolumeHookKind;
typedef enum {
    VCVolumeHookShapeDirectionalNoArgument = 1,
    VCVolumeHookShapeDirectionalInteger = 2,
    VCVolumeHookShapeDelta = 3,
} VCVolumeHookShape;
typedef struct {
    Class runtimeClass;
    SEL selector;
    _Atomic(IMP) original;
    int8_t direction;
    uint8_t kind;
} VCVolumeHookEntry;
typedef struct {
    Class nodeClass;
    VCEmitSampleBufferFunction original;
} VCNodeOutputHook;

typedef struct {
    _Atomic(Class) runtimeClass;
    _Atomic(VCEmitSampleBufferFunction) original;
} VCNodeOutputDispatchEntry;

static const NSUInteger VCMaximumNodeOutputHooks = 64;
static VCNodeOutputHook VCNodeOutputHooks[64];
static _Atomic(uint32_t) VCNodeOutputHookCount = 0;
static const NSUInteger VCNodeOutputDispatchCacheSize = 128;
static VCNodeOutputDispatchEntry VCNodeOutputDispatchCache[128];
static BOOL VCMediaServerHookInstalled = NO;
static BOOL VCMediaServerRetryScheduled = NO;
static _Atomic(uint32_t) VCMediaServerRescanScheduled = 0;
static BOOL VCMediaServerCanQueryVideoMediaType = NO;
static BOOL VCMediaServerCanQueryAudioMediaType = NO;
static SEL VCMediaTypeIsVideoSelector = NULL;
static SEL VCMediaTypeIsAudioSelector = NULL;
static dispatch_once_t VCConversionFailureLogToken;
static dispatch_once_t VCUnsupportedPixelFormatLogToken;
static dispatch_once_t VCHookUnavailableLogToken;
static CFStringRef const VCReplacedSampleAttachmentKey =
    CFSTR(VC_SYSTEM_REPLACEMENT_ATTACHMENT_KEY);
static char VCAudioReplacementContextAssociationKey;
static const NSUInteger VCMaximumVolumeHooks = 96;
static VCVolumeHookEntry VCVolumeHookEntries[96];
static _Atomic(uint32_t) VCVolumeHookCount = 0;
static BOOL VCVolumeUpHookInstalled = NO;
static BOOL VCVolumeDownHookInstalled = NO;
static uint8_t VCVolumeDirectionalHookCount = 0;
static uint8_t VCVolumeDeltaHookCount = 0;
static BOOL VCVolumeHookScanComplete = NO;
static const char *VCLocalVolumeHookStatusNotificationName =
    "com.murkaska.virtualcampro/local-volume-hook.status";
static int VCVolumeHookStatusToken = -1;

static void VCInstallMediaServerHook(NSUInteger attempt);
static void VCInstallSpringBoardVolumeHooks(NSUInteger attempt);
static Method VCDirectInstanceMethod(Class candidate, SEL selector);

static void VCPublishVolumeHookStatus(void) {
    // Keep the registration alive for SpringBoard's lifetime. Cancelling it
    // immediately after notify_set_state can discard the only owner of this
    // diagnostic state and makes Settings appear to scan forever.
    if (VCVolumeHookStatusToken < 0 &&
        notify_register_check(VCLocalVolumeHookStatusNotificationName,
                              &VCVolumeHookStatusToken) != NOTIFY_STATUS_OK) {
        VCVolumeHookStatusToken = -1;
        return;
    }
    uint64_t state = VCPackVolumeHookStatus(
        VCVolumeHookScanComplete,
        VCVolumeUpHookInstalled,
        VCVolumeDownHookInstalled,
        VCVolumeDeltaHookCount > 0,
        VCVolumeDirectionalHookCount,
        VCVolumeDeltaHookCount);
    if (notify_set_state(VCVolumeHookStatusToken, state) != NOTIFY_STATUS_OK) {
        notify_cancel(VCVolumeHookStatusToken);
        VCVolumeHookStatusToken = -1;
        return;
    }
    notify_post(VCLocalVolumeHookStatusNotificationName);
}

static BOOL VCMethodIsVoidWithNoExplicitArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'v';
}

static BOOL VCMethodIsVoidWithIntegerArgument(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char returnType[16] = {0};
    char argumentType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *type = argumentType;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') type++;
    return returnType[0] == 'v' && (type[0] == 'q' || type[0] == 'Q');
}

static VCVolumeHookKind VCVolumeDeltaHookKindForMethod(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return 0;
    char returnType[16] = {0};
    char argumentType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *type = argumentType;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') type++;
    if (returnType[0] != 'v') return 0;
    // iOS 15.5 declares -changeVolumeByDelta: as float, while some releases
    // expose a double/CGFloat variant. Each width needs a distinct trampoline.
    if (type[0] == 'f') return VCVolumeHookKindDeltaFloat;
    if (type[0] == 'd') return VCVolumeHookKindDeltaDouble;
    return 0;
}

static VCVolumeHookEntry *VCVolumeEntryForInvocation(id object, SEL selector) {
    if (!object || !selector) return NULL;
    uint32_t count = atomic_load_explicit(&VCVolumeHookCount, memory_order_acquire);
    for (Class current = object_getClass(object); current;
         current = class_getSuperclass(current)) {
        for (uint32_t index = 0; index < count; index++) {
            VCVolumeHookEntry *entry = &VCVolumeHookEntries[index];
            if (entry->runtimeClass == current && entry->selector == selector) {
                return entry;
            }
        }
    }
    return NULL;
}

static void VCSpringBoardVolumeButton(id object, SEL selector) {
    VCVolumeHookEntry *entry = VCVolumeEntryForInvocation(object, selector);
    int direction = entry ? entry->direction : 0;
    if (direction != 0 && [[VCStreamCoordinator sharedCoordinator]
            handleLocalMediaVolumeButtonDirection:direction]) return;
    VCVolumeButtonFunction original = entry
        ? (VCVolumeButtonFunction)atomic_load_explicit(&entry->original,
                                                       memory_order_acquire)
        : NULL;
    if (original) original(object, selector);
}

static void VCSpringBoardVolumeInteger(id object,
                                       SEL selector,
                                       long long modifiers) {
    VCVolumeHookEntry *entry = VCVolumeEntryForInvocation(object, selector);
    int direction = entry ? entry->direction : 0;
    if (direction != 0 && [[VCStreamCoordinator sharedCoordinator]
            handleLocalMediaVolumeButtonDirection:direction]) return;
    VCVolumeIntegerFunction original = entry
        ? (VCVolumeIntegerFunction)atomic_load_explicit(&entry->original,
                                                        memory_order_acquire)
        : NULL;
    if (original) original(object, selector, modifiers);
}

static BOOL VCConsumeVolumeDelta(double delta) {
    return isfinite(delta) && fabs(delta) > DBL_EPSILON &&
        [[VCStreamCoordinator sharedCoordinator]
            handleLocalMediaVolumeButtonDirection:delta > 0.0 ? 1 : -1];
}

static void VCSpringBoardVolumeFloatDelta(id object, SEL selector, float delta) {
    VCVolumeHookEntry *entry = VCVolumeEntryForInvocation(object, selector);
    if (VCConsumeVolumeDelta((double)delta)) return;
    VCVolumeFloatFunction original = entry
        ? (VCVolumeFloatFunction)atomic_load_explicit(&entry->original,
                                                      memory_order_acquire)
        : NULL;
    if (original) original(object, selector, delta);
}

static void VCSpringBoardVolumeDoubleDelta(id object, SEL selector, double delta) {
    VCVolumeHookEntry *entry = VCVolumeEntryForInvocation(object, selector);
    if (VCConsumeVolumeDelta(delta)) return;
    VCVolumeDoubleFunction original = entry
        ? (VCVolumeDoubleFunction)atomic_load_explicit(&entry->original,
                                                       memory_order_acquire)
        : NULL;
    if (original) original(object, selector, delta);
}

static BOOL VCVolumeHookAlreadyInstalled(Class runtimeClass, SEL selector) {
    uint32_t count = atomic_load_explicit(&VCVolumeHookCount, memory_order_acquire);
    for (uint32_t index = 0; index < count; index++) {
        VCVolumeHookEntry *entry = &VCVolumeHookEntries[index];
        if (entry->runtimeClass == runtimeClass && entry->selector == selector) {
            return YES;
        }
    }
    return NO;
}

static BOOL VCInstallVolumeHook(Class runtimeClass,
                                SEL selector,
                                VCVolumeHookShape shape,
                                int direction,
                                BOOL allowInheritedMethod) {
    if (!runtimeClass || !selector) return NO;
    Class hookClass = runtimeClass;
    Method method = VCDirectInstanceMethod(hookClass, selector);
    if (allowInheritedMethod) {
        while (!method && hookClass) {
            hookClass = class_getSuperclass(hookClass);
            method = hookClass ? VCDirectInstanceMethod(hookClass, selector) : NULL;
        }
    }
    if (!hookClass || VCVolumeHookAlreadyInstalled(hookClass, selector)) return NO;
    VCVolumeHookKind kind = 0;
    if (shape == VCVolumeHookShapeDirectionalNoArgument &&
        VCMethodIsVoidWithNoExplicitArguments(method)) {
        kind = VCVolumeHookKindDirectionalNoArgument;
    } else if (shape == VCVolumeHookShapeDirectionalInteger &&
               VCMethodIsVoidWithIntegerArgument(method)) {
        kind = VCVolumeHookKindDirectionalInteger;
    } else if (shape == VCVolumeHookShapeDelta) {
        kind = VCVolumeDeltaHookKindForMethod(method);
    }
    if (kind == 0) return NO;

    uint32_t index = atomic_load_explicit(&VCVolumeHookCount, memory_order_relaxed);
    if (index >= VCMaximumVolumeHooks) return NO;
    VCVolumeHookEntry *entry = &VCVolumeHookEntries[index];
    entry->runtimeClass = hookClass;
    entry->selector = selector;
    entry->direction = (int8_t)direction;
    entry->kind = (uint8_t)kind;
    atomic_store_explicit(&entry->original,
                          method_getImplementation(method),
                          memory_order_relaxed);
    atomic_store_explicit(&VCVolumeHookCount, index + 1, memory_order_release);

    IMP original = NULL;
    IMP replacement = kind == VCVolumeHookKindDirectionalNoArgument
        ? (IMP)VCSpringBoardVolumeButton
        : (kind == VCVolumeHookKindDirectionalInteger
            ? (IMP)VCSpringBoardVolumeInteger
            : (kind == VCVolumeHookKindDeltaFloat
                ? (IMP)VCSpringBoardVolumeFloatDelta
                : (IMP)VCSpringBoardVolumeDoubleDelta));
    MSHookMessageEx(hookClass, selector, replacement, &original);
    if (original) {
        atomic_store_explicit(&entry->original, original, memory_order_release);
    }
    if (kind == VCVolumeHookKindDeltaFloat ||
        kind == VCVolumeHookKindDeltaDouble) {
        if (VCVolumeDeltaHookCount < UINT8_MAX) VCVolumeDeltaHookCount++;
    } else {
        if (VCVolumeDirectionalHookCount < UINT8_MAX) VCVolumeDirectionalHookCount++;
        if (direction > 0) VCVolumeUpHookInstalled = YES;
        if (direction < 0) VCVolumeDownHookInstalled = YES;
    }
    return YES;
}

static int VCVolumeDirectionForSelectorName(NSString *selectorName) {
    NSString *name = selectorName.lowercaseString;
    if (![name containsString:@"volume"] || [name containsString:@":"] ||
        [name containsString:@"delta"] || [name containsString:@"changed"] ||
        [name containsString:@"notification"] || [name containsString:@"pressup"] ||
        [name containsString:@"buttonup"] || [name containsString:@"release"] ||
        [name containsString:@"cancel"] || [name containsString:@"send"] ||
        [name containsString:@"log"] || [name hasPrefix:@"set"] ||
        [name hasPrefix:@"can"] || [name hasPrefix:@"should"]) return 0;
    if ([name containsString:@"increase"] || [name containsString:@"volumeup"] ||
        [name containsString:@"stepup"]) return 1;
    if ([name containsString:@"decrease"] || [name containsString:@"volumedown"] ||
        [name containsString:@"stepdown"]) return -1;
    return 0;
}

static BOOL VCSelectorLooksLikeVolumeDelta(NSString *selectorName) {
    NSString *name = selectorName.lowercaseString;
    return [name containsString:@"volume"] && [name containsString:@"delta"];
}

static void VCScanKnownVolumeClasses(void) {
    const char *classNames[] = {
        "SBVolumeControl",
        "VolumeControl",
        "SBMediaController",
        "SBVolumeHardwareButtonActions",
        "SBVolumeHardwareButton",
        "SBVolumeButtonController",
        "SBHardwareButtonService",
    };
    const char *upSelectors[] = {
        "increaseVolume", "_increaseVolume", "volumeUp", "_volumeUp",
        "volumeIncrease", "_volumeIncrease", "handleVolumeUp",
        "_handleVolumeUp", "volumeUpButtonPressed",
        "volumeIncreaseButtonPressed", "performVolumeUp", "_performVolumeUp",
        "volumeIncreasePressDown", "_volumeIncreasePressDown",
        "volumeUpPressDown", "_volumeUpPressDown",
    };
    const char *downSelectors[] = {
        "decreaseVolume", "_decreaseVolume", "volumeDown", "_volumeDown",
        "volumeDecrease", "_volumeDecrease", "handleVolumeDown",
        "_handleVolumeDown", "volumeDownButtonPressed",
        "volumeDecreaseButtonPressed", "performVolumeDown", "_performVolumeDown",
        "volumeDecreasePressDown", "_volumeDecreasePressDown",
        "volumeDownPressDown", "_volumeDownPressDown",
    };
    const char *deltaSelectors[] = {
        "_changeVolumeByDelta:", "changeVolumeByDelta:",
        "adjustVolumeByDelta:", "_adjustVolumeByDelta:",
    };
    const char *upIntegerSelectors[] = {
        "volumeIncreasePressDownWithModifiers:",
    };
    const char *downIntegerSelectors[] = {
        "volumeDecreasePressDownWithModifiers:",
    };
    for (NSUInteger classIndex = 0;
         classIndex < sizeof(classNames) / sizeof(classNames[0]); classIndex++) {
        Class runtimeClass = objc_getClass(classNames[classIndex]);
        if (!runtimeClass) continue;
        for (NSUInteger index = 0;
             index < sizeof(upSelectors) / sizeof(upSelectors[0]); index++) {
            VCInstallVolumeHook(runtimeClass, sel_registerName(upSelectors[index]),
                                VCVolumeHookShapeDirectionalNoArgument, 1, YES);
        }
        for (NSUInteger index = 0;
             index < sizeof(downSelectors) / sizeof(downSelectors[0]); index++) {
            VCInstallVolumeHook(runtimeClass, sel_registerName(downSelectors[index]),
                                VCVolumeHookShapeDirectionalNoArgument, -1, YES);
        }
        for (NSUInteger index = 0;
             index < sizeof(upIntegerSelectors) / sizeof(upIntegerSelectors[0]); index++) {
            VCInstallVolumeHook(runtimeClass,
                                sel_registerName(upIntegerSelectors[index]),
                                VCVolumeHookShapeDirectionalInteger, 1, YES);
        }
        for (NSUInteger index = 0;
             index < sizeof(downIntegerSelectors) / sizeof(downIntegerSelectors[0]); index++) {
            VCInstallVolumeHook(runtimeClass,
                                sel_registerName(downIntegerSelectors[index]),
                                VCVolumeHookShapeDirectionalInteger, -1, YES);
        }
        for (NSUInteger index = 0;
             index < sizeof(deltaSelectors) / sizeof(deltaSelectors[0]); index++) {
            VCInstallVolumeHook(runtimeClass, sel_registerName(deltaSelectors[index]),
                                VCVolumeHookShapeDelta, 0, YES);
        }
    }
}

static void VCScanLoadedVolumeClasses(void) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;
    Class __unsafe_unretained *classes =
        (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);
    for (int classIndex = 0; classIndex < classCount; classIndex++) {
        Class runtimeClass = classes[classIndex];
        NSString *className = NSStringFromClass(runtimeClass).lowercaseString;
        if (![className containsString:@"volume"]) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(runtimeClass, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            SEL selector = method_getName(methods[methodIndex]);
            NSString *selectorName = NSStringFromSelector(selector);
            int direction = VCVolumeDirectionForSelectorName(selectorName);
            if (direction != 0) {
                VCInstallVolumeHook(runtimeClass, selector,
                                    VCVolumeHookShapeDirectionalNoArgument,
                                    direction, NO);
            } else if (VCSelectorLooksLikeVolumeDelta(selectorName)) {
                VCInstallVolumeHook(runtimeClass, selector,
                                    VCVolumeHookShapeDelta, 0, NO);
            }
        }
        free(methods);
    }
    free(classes);
}

static void VCInstallSpringBoardVolumeHooks(NSUInteger attempt) {
    uint32_t previousCount = atomic_load_explicit(&VCVolumeHookCount,
                                                   memory_order_acquire);
    VCScanKnownVolumeClasses();
    VCScanLoadedVolumeClasses();
    BOOL usable = (VCVolumeUpHookInstalled && VCVolumeDownHookInstalled) ||
        VCVolumeDeltaHookCount > 0;
    if (usable || attempt >= 20) VCVolumeHookScanComplete = YES;
    uint32_t currentCount = atomic_load_explicit(&VCVolumeHookCount,
                                                  memory_order_acquire);
    if (attempt == 0 || previousCount != currentCount || VCVolumeHookScanComplete) {
        VCPublishVolumeHookStatus();
    }
    if (usable) {
        NSLog(@"[VirtualCamPro] SpringBoard volume hooks installed "
               "(directional=%u, delta=%u)",
              VCVolumeDirectionalHookCount, VCVolumeDeltaHookCount);
        return;
    }
    NSTimeInterval delay = attempt < 20 ? 0.5 : 15.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // SpringBoard private classes can arrive after tweak initialization;
        // continuing low-frequency scans keeps iOS 15 point releases covered.
        VCInstallSpringBoardVolumeHooks(attempt + 1);
    });
}

static BOOL VCMethodAcceptsSampleBuffer(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;

    char returnType[16] = {0};
    char argumentType[128] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));

    const char *unqualifiedType = argumentType;
    while (*unqualifiedType == 'r' || *unqualifiedType == 'n' ||
           *unqualifiedType == 'N' || *unqualifiedType == 'o' ||
           *unqualifiedType == 'O' || *unqualifiedType == 'R' ||
           *unqualifiedType == 'V') {
        unqualifiedType++;
    }
    return returnType[0] == 'v' && unqualifiedType[0] == '^';
}

static BOOL VCMethodReturnsBoolean(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    char returnType[16] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *unqualifiedType = returnType;
    while (*unqualifiedType == 'r' || *unqualifiedType == 'n' ||
           *unqualifiedType == 'N' || *unqualifiedType == 'o' ||
           *unqualifiedType == 'O' || *unqualifiedType == 'R' ||
           *unqualifiedType == 'V') {
        unqualifiedType++;
    }
    return unqualifiedType[0] == 'B' || unqualifiedType[0] == 'c';
}

static BOOL VCNodeOutputIsVideo(id object) {
    if (!VCMediaServerCanQueryVideoMediaType || !VCMediaTypeIsVideoSelector) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, VCMediaTypeIsVideoSelector);
}

static BOOL VCNodeOutputIsAudio(id object) {
    if (!VCMediaServerCanQueryAudioMediaType || !VCMediaTypeIsAudioSelector) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, VCMediaTypeIsAudioSelector);
}

static VCAudioReplacementContext *VCAudioContextForNode(id object) {
    if (!object) return nil;
    @synchronized (object) {
        VCAudioReplacementContext *context = objc_getAssociatedObject(
            object,
            &VCAudioReplacementContextAssociationKey);
        if (!context) {
            context = [VCAudioReplacementContext new];
            objc_setAssociatedObject(object,
                                     &VCAudioReplacementContextAssociationKey,
                                     context,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return context;
    }
}

static NSUInteger VCNodeOutputDispatchIndex(Class runtimeClass) {
    return (((uintptr_t)runtimeClass) >> 4) &
        (VCNodeOutputDispatchCacheSize - 1);
}

static VCEmitSampleBufferFunction VCCachedOriginalEmitForClass(Class runtimeClass) {
    if (!runtimeClass) return NULL;
    NSUInteger start = VCNodeOutputDispatchIndex(runtimeClass);
    for (NSUInteger probe = 0; probe < VCNodeOutputDispatchCacheSize; probe++) {
        NSUInteger index = (start + probe) & (VCNodeOutputDispatchCacheSize - 1);
        Class cachedClass = atomic_load_explicit(
            &VCNodeOutputDispatchCache[index].runtimeClass,
            memory_order_acquire);
        if (cachedClass == runtimeClass) {
            return atomic_load_explicit(&VCNodeOutputDispatchCache[index].original,
                                        memory_order_acquire);
        }
        if (!cachedClass) return NULL;
    }
    return NULL;
}

static void VCCacheOriginalEmitForClass(Class runtimeClass,
                                        VCEmitSampleBufferFunction original) {
    if (!runtimeClass || !original) return;
    NSUInteger start = VCNodeOutputDispatchIndex(runtimeClass);
    for (NSUInteger probe = 0; probe < VCNodeOutputDispatchCacheSize; probe++) {
        NSUInteger index = (start + probe) & (VCNodeOutputDispatchCacheSize - 1);
        Class cachedClass = atomic_load_explicit(
            &VCNodeOutputDispatchCache[index].runtimeClass,
            memory_order_acquire);
        if (cachedClass == runtimeClass) {
            atomic_store_explicit(&VCNodeOutputDispatchCache[index].original,
                                  original,
                                  memory_order_release);
            return;
        }
        if (!cachedClass) {
            Class empty = Nil;
            if (atomic_compare_exchange_strong_explicit(
                    &VCNodeOutputDispatchCache[index].runtimeClass,
                    &empty,
                    runtimeClass,
                    memory_order_acq_rel,
                    memory_order_acquire)) {
                atomic_store_explicit(&VCNodeOutputDispatchCache[index].original,
                                      original,
                                      memory_order_release);
                return;
            }
        }
    }
}

static VCEmitSampleBufferFunction VCOriginalEmitForObject(id object) {
    Class runtimeClass = object_getClass(object);
    VCEmitSampleBufferFunction cached =
        VCCachedOriginalEmitForClass(runtimeClass);
    if (cached) return cached;
    uint32_t count = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_acquire);
    for (Class current = runtimeClass; current; current = class_getSuperclass(current)) {
        for (uint32_t index = 0; index < count; index++) {
            if (VCNodeOutputHooks[index].nodeClass == current) {
                VCEmitSampleBufferFunction original =
                    VCNodeOutputHooks[index].original;
                VCCacheOriginalEmitForClass(runtimeClass, original);
                return original;
            }
        }
    }
    return NULL;
}

static void VCMediaServerEmitSampleBuffer(id object, SEL selector, CMSampleBufferRef originalBuffer) {
    VCEmitSampleBufferFunction originalEmit = VCOriginalEmitForObject(object);
    if (!originalEmit) return;
    @autoreleasepool {
        if (!originalBuffer) {
            originalEmit(object, selector, originalBuffer);
            return;
        }
        if (CMGetAttachment(originalBuffer,
                            VCReplacedSampleAttachmentKey,
                            NULL) == kCFBooleanTrue) {
            originalEmit(object, selector, originalBuffer);
            return;
        }

        // When the user chooses explicit target applications, the system-wide
        // BW pipeline is enabled only while one of those injected processes is
        // publishing a fresh camera-session heartbeat. An empty target list
        // intentionally preserves the historical global behavior.
        VCPreferences *preferences = VCPreferences.sharedPreferences;
        if (preferences.hasTargetBundleFilter &&
            !VCTargetCaptureIsActive(3.0)) {
            originalEmit(object, selector, originalBuffer);
            return;
        }

        CVPixelBufferRef originalPixelBuffer = CMSampleBufferGetImageBuffer(originalBuffer);
        if (originalPixelBuffer && VCNodeOutputIsVideo(object)) {
            OSType originalPixelFormat = CVPixelBufferGetPixelFormatType(originalPixelBuffer);
            if (!VCIsSupportedReplacementPixelFormat(originalPixelFormat)) {
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeUnsupportedPixelFormat,
                    0);
                dispatch_once(&VCUnsupportedPixelFormatLogToken, ^{
                    NSLog(@"[VirtualCamPro] Preserving non-color BWNodeOutput pixel format %u",
                          (unsigned int)originalPixelFormat);
                });
                originalEmit(object, selector, originalBuffer);
                return;
            }

            VCStreamCoordinator *coordinator = VCStreamCoordinator.sharedCoordinator;
            BOOL aspectFill = YES;
            NSInteger preferredFPS = 60;
            CVPixelBufferRef source = [coordinator
                copyLatestPixelBufferWithAspectFill:&aspectFill preferredFPS:&preferredFPS];
            if (!source) {
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeSourceUnavailable,
                    (uint8_t)VCSharedVideoLastFailureReason());
                originalEmit(object, selector, originalBuffer);
                return;
            }
            CMSampleBufferRef replacement = VCCopyReplacementSampleBuffer(originalBuffer,
                                                                           source,
                                                                           aspectFill,
                                                                           preferredFPS);
            VCReleaseSharedVideoPixelBuffer(source);
            if (!replacement) {
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeConversionFailed,
                    0);
                dispatch_once(&VCConversionFailureLogToken, ^{
                    NSLog(@"[VirtualCamPro] System video conversion failed for %zux%zu/%u; fail-open",
                          CVPixelBufferGetWidth(originalPixelBuffer),
                          CVPixelBufferGetHeight(originalPixelBuffer),
                          (unsigned int)originalPixelFormat);
                });
            } else {
                CMSetAttachment(replacement,
                                VCReplacedSampleAttachmentKey,
                                kCFBooleanTrue,
                                kCMAttachmentMode_ShouldPropagate);
                CVPixelBufferRef replacementPixelBuffer =
                    CMSampleBufferGetImageBuffer(replacement);
                if (replacementPixelBuffer) {
                    CVBufferSetAttachment(replacementPixelBuffer,
                                          VCReplacedSampleAttachmentKey,
                                          kCFBooleanTrue,
                                          kCVAttachmentMode_ShouldPropagate);
                }
            }
            originalEmit(object, selector, replacement ?: originalBuffer);
            if (replacement) {
                VCMarkSystemPipelineActivity(VCSharedMediaKindVideo);
                VCReportMediaServerVideoRuntimeEvent(
                    VCMediaServerVideoRuntimeReplacementSucceeded,
                    0);
                CFRelease(replacement);
            }
            return;
        }

        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(originalBuffer);
        const AudioStreamBasicDescription *asbd = format
            ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
        if (asbd && VCNodeOutputIsAudio(object) &&
            [[VCSharedAudioClient sharedClient] hasPublishedAudioWithMaximumAge:2.0]) {
            CMSampleBufferRef replacement =
                VCCopyReplacementAudioSampleBuffer(originalBuffer,
                                                    VCAudioContextForNode(object));
            if (replacement) {
                CMSetAttachment(replacement,
                                VCReplacedSampleAttachmentKey,
                                kCFBooleanTrue,
                                kCMAttachmentMode_ShouldPropagate);
            }
            originalEmit(object, selector, replacement ?: originalBuffer);
            if (replacement) {
                VCMarkSystemPipelineActivity(VCSharedMediaKindAudio);
                CFRelease(replacement);
            }
            return;
        }

        // Depth, disparity, metadata and compressed auxiliary streams never
        // enter either replacement path.
        originalEmit(object, selector, originalBuffer);
    }
}

static BOOL VCClassIsSubclassOfClass(Class candidate, Class baseClass) {
    for (Class current = candidate; current; current = class_getSuperclass(current)) {
        if (current == baseClass) return YES;
    }
    return NO;
}

static Method VCDirectInstanceMethod(Class candidate, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(candidate, &methodCount);
    Method result = NULL;
    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL VCClassAlreadyHooked(Class candidate) {
    uint32_t count = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_acquire);
    for (uint32_t index = 0; index < count; index++) {
        if (VCNodeOutputHooks[index].nodeClass == candidate) return YES;
    }
    return NO;
}

static BOOL VCHookNodeOutputClass(Class candidate,
                                  SEL emitSelector,
                                  BOOL allowInheritedMethod) {
    if (!candidate || VCClassAlreadyHooked(candidate)) return NO;
    // Some iOS 15 point releases inherit emitSampleBuffer: into BWNodeOutput
    // instead of declaring it directly. Hook that inherited implementation at
    // the BWNodeOutput boundary, while subclasses are still limited to direct
    // overrides so the same inherited IMP is never wrapped repeatedly.
    Method method = allowInheritedMethod
        ? class_getInstanceMethod(candidate, emitSelector)
        : VCDirectInstanceMethod(candidate, emitSelector);
    if (!method) return NO;
    if (!VCMethodAcceptsSampleBuffer(method)) {
        VCReportMediaServerVideoRuntimeEvent(
            VCMediaServerVideoRuntimeIncompatibleSignature,
            0);
        NSLog(@"[VirtualCamPro] Refusing unexpected %@ emitSampleBuffer: signature",
              NSStringFromClass(candidate));
        return NO;
    }
    uint32_t slot = atomic_load_explicit(&VCNodeOutputHookCount, memory_order_relaxed);
    if (slot >= VCMaximumNodeOutputHooks) {
        VCReportMediaServerVideoRuntimeEvent(
            VCMediaServerVideoRuntimeHookCapacityExceeded,
            UINT8_MAX);
        NSLog(@"[VirtualCamPro] BWNodeOutput subclass hook limit reached");
        return NO;
    }
    VCNodeOutputHooks[slot].nodeClass = candidate;
    VCNodeOutputHooks[slot].original =
        (VCEmitSampleBufferFunction)method_getImplementation(method);
    atomic_store_explicit(&VCNodeOutputHookCount, slot + 1, memory_order_release);
    MSHookMessageEx(candidate,
                    emitSelector,
                    (IMP)VCMediaServerEmitSampleBuffer,
                    (IMP *)&VCNodeOutputHooks[slot].original);
    VCCacheOriginalEmitForClass(candidate, VCNodeOutputHooks[slot].original);
    return VCNodeOutputHooks[slot].original != NULL;
}

static void VCScheduleMediaServerHookRetry(NSUInteger attempt,
                                           NSTimeInterval delay) {
    if (VCMediaServerRetryScheduled) return;
    VCMediaServerRetryScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        VCMediaServerRetryScheduled = NO;
        VCInstallMediaServerHook(attempt);
    });
}

static void VCInstallMediaServerHook(NSUInteger attempt) {
    VCReportMediaServerVideoRuntimeEvent(
        VCMediaServerVideoRuntimeScanning,
        (uint8_t)MIN(attempt, (NSUInteger)UINT8_MAX));
    Class nodeOutputClass = objc_getClass("BWNodeOutput");
    SEL emitSelector = sel_registerName("emitSampleBuffer:");
    if (nodeOutputClass) {
        VCMediaTypeIsVideoSelector = sel_registerName("mediaTypeIsVideo");
        Method videoMethod = class_getInstanceMethod(nodeOutputClass,
                                                      VCMediaTypeIsVideoSelector);
        VCMediaServerCanQueryVideoMediaType = VCMethodReturnsBoolean(videoMethod);
        VCMediaTypeIsAudioSelector = sel_registerName("mediaTypeIsAudio");
        Method audioMethod = class_getInstanceMethod(nodeOutputClass,
                                                      VCMediaTypeIsAudioSelector);
        VCMediaServerCanQueryAudioMediaType = VCMethodReturnsBoolean(audioMethod);
        uint32_t previousCount = atomic_load_explicit(&VCNodeOutputHookCount,
                                                       memory_order_acquire);
        VCHookNodeOutputClass(nodeOutputClass, emitSelector, YES);

        int classCount = objc_getClassList(NULL, 0);
        if (classCount > 0) {
            Class __unsafe_unretained *classes =
                (__unsafe_unretained Class *)calloc((size_t)classCount,
                                                     sizeof(Class));
            int populated = classes ? objc_getClassList(classes, classCount) : 0;
            for (int index = 0; index < populated; index++) {
                Class candidate = classes[index];
                if (candidate != nodeOutputClass &&
                    VCClassIsSubclassOfClass(candidate, nodeOutputClass)) {
                    VCHookNodeOutputClass(candidate, emitSelector, NO);
                }
            }
            free(classes);
        }
        uint32_t installedCount = atomic_load_explicit(&VCNodeOutputHookCount,
                                                        memory_order_acquire);
        VCMediaServerHookInstalled = installedCount > 0;
        if (VCMediaServerHookInstalled) {
            VCReportMediaServerVideoRuntimeEvent(
                VCMediaServerVideoRuntimeHookInstalled,
                (uint8_t)MIN(installedCount, (uint32_t)UINT8_MAX));
        }
        if (installedCount != previousCount) {
            NSLog(@"[VirtualCamPro] mediaserverd BWNodeOutput hooks %@ (%u classes, video %@, audio %@)",
                  VCMediaServerHookInstalled ? @"installed" : @"failed",
                  installedCount,
                  VCMediaServerCanQueryVideoMediaType ? @"typed" : @"sample-classified",
                  VCMediaServerCanQueryAudioMediaType ? @"typed" : @"sample-classified");
        }
        if (VCMediaServerHookInstalled) return;
    }

    if (attempt >= 20) {
        VCMediaServerVideoRuntimeEvent event = nodeOutputClass
            ? VCMediaServerVideoRuntimeIncompatibleSignature
            : VCMediaServerVideoRuntimeNodeClassUnavailable;
        VCReportMediaServerVideoRuntimeEvent(event, 0);
        dispatch_once(&VCHookUnavailableLogToken, ^{
            NSLog(@"[VirtualCamPro] BWNodeOutput has no compatible "
                   "emitSampleBuffer: entry point yet; continuing low-frequency scans");
        });
        // Camera internals can register well after mediaserverd starts. Keep a
        // low-frequency scan alive instead of making the first ten seconds a
        // permanent success/failure boundary.
        VCScheduleMediaServerHookRetry(attempt, 5.0);
        return;
    }
    VCScheduleMediaServerHookRetry(attempt + 1, 0.5);
}

static void VCMediaServerImageDidLoad(const struct mach_header *header, intptr_t slide) {
    if (atomic_exchange_explicit(&VCMediaServerRescanScheduled,
                                 1,
                                 memory_order_acq_rel) != 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store_explicit(&VCMediaServerRescanScheduled, 0, memory_order_release);
        VCInstallMediaServerHook(0);
    });
}


%ctor {
    @autoreleasepool {
        NSString *processName = NSProcessInfo.processInfo.processName;
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if ([processName isEqualToString:@"SpringBoard"] ||
            [bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            VCStartSharedRuntimeHeartbeat(VCSharedRuntimeProcessSpringBoard);
            VCPreferences *preferences = VCPreferences.sharedPreferences;
            [preferences reload];
            [preferences publishSharedConfiguration];
            [[VCStreamCoordinator sharedCoordinator] startMonitoring];
            dispatch_async(dispatch_get_main_queue(), ^{
                VCInstallSpringBoardVolumeHooks(0);
            });
            return;
        }
        if (![processName isEqualToString:@"mediaserverd"]) return;
        VCStartSharedRuntimeHeartbeat(VCSharedRuntimeProcessMediaServer);
        VCReportMediaServerVideoRuntimeEvent(
            VCMediaServerVideoRuntimeInjected,
            0);
        [[VCStreamCoordinator sharedCoordinator] startMonitoring];
        _dyld_register_func_for_add_image(VCMediaServerImageDidLoad);
        dispatch_async(dispatch_get_main_queue(), ^{
            VCInstallMediaServerHook(0);
        });
    }
}
