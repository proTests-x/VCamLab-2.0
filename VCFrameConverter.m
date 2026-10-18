#import "VCFrameConverter.h"

#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#import <VideoToolbox/VideoToolbox.h>
#import <float.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>

// Cache/pool metadata and the VideoToolbox transfer session have different
// contention profiles. Cache hits must not wait behind a GPU transfer already
// running for another BW output node.
static os_unfair_lock VCFrameStateLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock VCPixelTransferSessionLock = OS_UNFAIR_LOCK_INIT;
static VTPixelTransferSessionRef VCTransferSession = NULL;
static CIContext *VCOrientationContext = nil;

static double VCMillisecondsBetweenMachTicks(uint64_t start, uint64_t end) {
    if (end < start) return 0.0;
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mach_timebase_info(&timebase); });
    long double nanos = ((long double)(end - start) * timebase.numer) / timebase.denom;
    return (double)(nanos / 1000000.0L);
}

static void VCLogSlowPixelTransfer(uint64_t started,
                                   uint64_t sessionAcquired,
                                   uint64_t transferFinished,
                                   size_t width,
                                   size_t height,
                                   OSType pixelFormat) {
    double totalMilliseconds = VCMillisecondsBetweenMachTicks(started,
                                                               transferFinished);
    if (totalMilliseconds < 12.0) return;
    static _Atomic(uint64_t) lastLogTicks = 0;
    uint64_t observed = atomic_load_explicit(&lastLogTicks, memory_order_relaxed);
    double sinceLastLog = observed == 0
        ? DBL_MAX : VCMillisecondsBetweenMachTicks(observed, transferFinished);
    if (sinceLastLog < 5000.0 ||
        !atomic_compare_exchange_strong_explicit(&lastLogTicks,
                                                  &observed,
                                                  transferFinished,
                                                  memory_order_relaxed,
                                                  memory_order_relaxed)) {
        return;
    }
    NSLog(@"[VirtualCamPro] Slow pixel transfer %zux%zu/%u: wait=%.2fms transfer=%.2fms total=%.2fms",
          width,
          height,
          (unsigned int)pixelFormat,
          VCMillisecondsBetweenMachTicks(started, sessionAcquired),
          VCMillisecondsBetweenMachTicks(sessionAcquired, transferFinished),
          totalMilliseconds);
}

static CGColorSpaceRef VCSharedDeviceRGBColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return colorSpace;
}

enum {
    VCMaximumCachedFormats = 12,
    VCMaximumOutstandingBuffersPerFormat = 6,
    VCMaximumConvertedFrameCacheBytes = 64 * 1024 * 1024,
};

typedef struct {
    size_t width;
    size_t height;
    OSType pixelFormat;
    CVPixelBufferPoolRef pool;
    uint64_t lastUse;
} VCPixelBufferPoolEntry;

typedef struct {
    CVPixelBufferRef sourceBuffer;
    size_t width;
    size_t height;
    OSType pixelFormat;
    BOOL aspectFill;
    CMFormatDescriptionRef templateDescription;
    CMVideoFormatDescriptionRef replacementDescription;
    CVPixelBufferRef buffer;
    size_t byteCost;
    uint64_t lastUse;
} VCConvertedFrameEntry;

static VCPixelBufferPoolEntry VCPixelBufferPoolEntries[VCMaximumCachedFormats];
static VCConvertedFrameEntry VCConvertedFrameEntries[VCMaximumCachedFormats];
static size_t VCPixelBufferPoolEntryCount = 0;
static size_t VCConvertedFrameEntryCount = 0;
static uint64_t VCPixelBufferPoolUseCounter = 0;
static uint64_t VCConvertedFrameUseCounter = 0;
static size_t VCConvertedFrameCachedBytes = 0;

static CFDictionaryRef VCBoundedPixelBufferAllocationAttributes(void) {
    static NSDictionary *attributes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        attributes = @{
            (id)kCVPixelBufferPoolAllocationThresholdKey:
                @(VCMaximumOutstandingBuffersPerFormat),
        };
    });
    return (__bridge CFDictionaryRef)attributes;
}

static CVPixelBufferRef VCCopyPixelBufferMatchingTemplateAndDescription(
    CVPixelBufferRef source,
    CVPixelBufferRef templateBuffer,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription,
    CMVideoFormatDescriptionRef _Nullable * _Nullable replacementDescriptionOut) CF_RETURNS_RETAINED;

BOOL VCIsSupportedReplacementPixelFormat(OSType pixelFormat) {
    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8Planar:
        case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        case kCVPixelFormatType_422YpCbCr8:
        case kCVPixelFormatType_422YpCbCr8_yuvs:
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_32ARGB:
            return YES;
        default:
            return NO;
    }
}

static void VCCopyDictionaryEntry(const void *key, const void *value, void *context) {
    CFDictionarySetValue((CFMutableDictionaryRef)context, key, value);
}

static VTPixelTransferSessionRef VCLockedTransferSession(void) {
    if (!VCTransferSession) {
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &VCTransferSession);
        if (VCTransferSession) {
            VTSessionSetProperty(VCTransferSession,
                                 kVTPixelTransferPropertyKey_RealTime,
                                 kCFBooleanTrue);
        }
    }
    return VCTransferSession;
}

static CIContext *VCSharedOrientationContext(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCOrientationContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextCacheIntermediates: @NO,
        }];
    });
    return VCOrientationContext;
}

static void VCLockedClearConvertedFrames(void) {
    for (size_t index = 0; index < VCConvertedFrameEntryCount; index++) {
        if (VCConvertedFrameEntries[index].sourceBuffer) {
            CVPixelBufferRelease(VCConvertedFrameEntries[index].sourceBuffer);
        }
        if (VCConvertedFrameEntries[index].buffer) {
            CVPixelBufferRelease(VCConvertedFrameEntries[index].buffer);
        }
        if (VCConvertedFrameEntries[index].templateDescription) {
            CFRelease(VCConvertedFrameEntries[index].templateDescription);
        }
        if (VCConvertedFrameEntries[index].replacementDescription) {
            CFRelease(VCConvertedFrameEntries[index].replacementDescription);
        }
        VCConvertedFrameEntries[index] = (VCConvertedFrameEntry){0};
    }
    VCConvertedFrameEntryCount = 0;
    VCConvertedFrameUseCounter = 0;
    VCConvertedFrameCachedBytes = 0;
}

static BOOL VCLockedConvertedFrameMatchesTarget(
    const VCConvertedFrameEntry *entry,
    size_t width,
    size_t height,
    OSType pixelFormat,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription) {
    return entry && entry->buffer && entry->width == width &&
        entry->height == height && entry->pixelFormat == pixelFormat &&
        entry->aspectFill == aspectFill &&
        (entry->templateDescription == templateDescription ||
         (entry->templateDescription && templateDescription &&
          CFEqual(entry->templateDescription, templateDescription)));
}

static CVPixelBufferRef VCLockedCopyConvertedFrame(
    CVPixelBufferRef source,
    size_t width,
    size_t height,
    OSType pixelFormat,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription,
    CMVideoFormatDescriptionRef *replacementDescriptionOut) {
    for (size_t index = 0; index < VCConvertedFrameEntryCount; index++) {
        VCConvertedFrameEntry *entry = &VCConvertedFrameEntries[index];
        if (entry->sourceBuffer == source &&
            VCLockedConvertedFrameMatchesTarget(entry,
                                                 width,
                                                 height,
                                                 pixelFormat,
                                                 aspectFill,
                                                 templateDescription)) {
            entry->lastUse = ++VCConvertedFrameUseCounter;
            if (replacementDescriptionOut && entry->replacementDescription) {
                *replacementDescriptionOut =
                    (CMVideoFormatDescriptionRef)CFRetain(entry->replacementDescription);
            }
            return CVPixelBufferRetain(entry->buffer);
        }
    }
    return NULL;
}

static CVPixelBufferRef VCLockedCopyMostRecentConvertedFrame(
    size_t width,
    size_t height,
    OSType pixelFormat,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription,
    CMVideoFormatDescriptionRef *replacementDescriptionOut) {
    VCConvertedFrameEntry *newest = NULL;
    for (size_t index = 0; index < VCConvertedFrameEntryCount; index++) {
        VCConvertedFrameEntry *entry = &VCConvertedFrameEntries[index];
        if (VCLockedConvertedFrameMatchesTarget(entry,
                                                width,
                                                height,
                                                pixelFormat,
                                                aspectFill,
                                                templateDescription) &&
            (!newest || entry->lastUse > newest->lastUse)) {
            newest = entry;
        }
    }
    if (!newest) return NULL;
    newest->lastUse = ++VCConvertedFrameUseCounter;
    if (replacementDescriptionOut && newest->replacementDescription) {
        *replacementDescriptionOut =
            (CMVideoFormatDescriptionRef)CFRetain(newest->replacementDescription);
    }
    return CVPixelBufferRetain(newest->buffer);
}

static void VCLockedRemoveConvertedFrameAtIndex(size_t index) {
    if (index >= VCConvertedFrameEntryCount) return;
    VCConvertedFrameEntry *entry = &VCConvertedFrameEntries[index];
    VCConvertedFrameCachedBytes = entry->byteCost <= VCConvertedFrameCachedBytes
        ? VCConvertedFrameCachedBytes - entry->byteCost : 0;
    if (entry->sourceBuffer) CVPixelBufferRelease(entry->sourceBuffer);
    if (entry->templateDescription) CFRelease(entry->templateDescription);
    if (entry->replacementDescription) CFRelease(entry->replacementDescription);
    if (entry->buffer) CVPixelBufferRelease(entry->buffer);
    size_t finalIndex = VCConvertedFrameEntryCount - 1;
    if (index != finalIndex) {
        *entry = VCConvertedFrameEntries[finalIndex];
    }
    VCConvertedFrameEntries[finalIndex] = (VCConvertedFrameEntry){0};
    VCConvertedFrameEntryCount--;
}

static size_t VCConvertedFrameByteCost(CVPixelBufferRef buffer) {
    if (!buffer) return 0;
    size_t byteCost = CVPixelBufferGetDataSize(buffer);
    if (byteCost > 0) return byteCost;
    size_t planeCount = CVPixelBufferGetPlaneCount(buffer);
    if (planeCount == 0) {
        size_t rowBytes = CVPixelBufferGetBytesPerRow(buffer);
        size_t height = CVPixelBufferGetHeight(buffer);
        return height > 0 && rowBytes <= SIZE_MAX / height ? rowBytes * height : 0;
    }
    for (size_t plane = 0; plane < planeCount; plane++) {
        size_t rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
        size_t height = CVPixelBufferGetHeightOfPlane(buffer, plane);
        if (height > 0 && rowBytes > SIZE_MAX / height) return 0;
        size_t planeBytes = rowBytes * height;
        if (planeBytes > SIZE_MAX - byteCost) return 0;
        byteCost += planeBytes;
    }
    return byteCost;
}

static void VCLockedStoreConvertedFrame(
    CVPixelBufferRef source,
    size_t width,
    size_t height,
    OSType pixelFormat,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription,
    CMVideoFormatDescriptionRef replacementDescription,
    CVPixelBufferRef buffer) {
    size_t byteCost = VCConvertedFrameByteCost(buffer);
    if (byteCost == 0 || byteCost > VCMaximumConvertedFrameCacheBytes) return;
    while (VCConvertedFrameEntryCount >= VCMaximumCachedFormats ||
           byteCost > VCMaximumConvertedFrameCacheBytes -
               VCConvertedFrameCachedBytes) {
        if (VCConvertedFrameEntryCount == 0) return;
        size_t oldestIndex = 0;
        for (size_t index = 1; index < VCConvertedFrameEntryCount; index++) {
            if (VCConvertedFrameEntries[index].lastUse <
                VCConvertedFrameEntries[oldestIndex].lastUse) {
                oldestIndex = index;
            }
        }
        VCLockedRemoveConvertedFrameAtIndex(oldestIndex);
    }
    size_t destinationIndex = VCConvertedFrameEntryCount++;
    VCConvertedFrameEntries[destinationIndex] = (VCConvertedFrameEntry){
        .sourceBuffer = CVPixelBufferRetain(source),
        .width = width,
        .height = height,
        .pixelFormat = pixelFormat,
        .aspectFill = aspectFill,
        .templateDescription = templateDescription
            ? (CMFormatDescriptionRef)CFRetain(templateDescription)
            : NULL,
        .replacementDescription = replacementDescription
            ? (CMVideoFormatDescriptionRef)CFRetain(replacementDescription)
            : NULL,
        .buffer = CVPixelBufferRetain(buffer),
        .byteCost = byteCost,
        .lastUse = ++VCConvertedFrameUseCounter,
    };
    VCConvertedFrameCachedBytes += byteCost;
}

static void VCLockedReleasePixelBufferPools(void) {
    for (size_t index = 0; index < VCPixelBufferPoolEntryCount; index++) {
        if (VCPixelBufferPoolEntries[index].pool) {
            CVPixelBufferPoolFlush(VCPixelBufferPoolEntries[index].pool,
                                   kCVPixelBufferPoolFlushExcessBuffers);
            CVPixelBufferPoolRelease(VCPixelBufferPoolEntries[index].pool);
        }
        VCPixelBufferPoolEntries[index] = (VCPixelBufferPoolEntry){0};
    }
    VCPixelBufferPoolEntryCount = 0;
    VCPixelBufferPoolUseCounter = 0;
}

static CVPixelBufferPoolRef VCLockedPixelBufferPool(size_t width,
                                                    size_t height,
                                                    OSType pixelFormat) {
    for (size_t index = 0; index < VCPixelBufferPoolEntryCount; index++) {
        VCPixelBufferPoolEntry *entry = &VCPixelBufferPoolEntries[index];
        if (entry->width == width && entry->height == height &&
            entry->pixelFormat == pixelFormat) {
            entry->lastUse = ++VCPixelBufferPoolUseCounter;
            return entry->pool;
        }
    }

    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{
            (id)kIOSurfaceIsGlobal: @YES,
        },
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferPoolRef createdPool = NULL;
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                              (__bridge CFDictionaryRef)poolAttributes,
                                              (__bridge CFDictionaryRef)bufferAttributes,
                                              &createdPool);
    if (result != kCVReturnSuccess || !createdPool) return NULL;

    size_t destinationIndex = VCPixelBufferPoolEntryCount;
    if (destinationIndex < VCMaximumCachedFormats) {
        VCPixelBufferPoolEntryCount++;
    } else {
        destinationIndex = 0;
        for (size_t index = 1; index < VCMaximumCachedFormats; index++) {
            if (VCPixelBufferPoolEntries[index].lastUse <
                VCPixelBufferPoolEntries[destinationIndex].lastUse) {
                destinationIndex = index;
            }
        }
        CVPixelBufferPoolFlush(VCPixelBufferPoolEntries[destinationIndex].pool,
                               kCVPixelBufferPoolFlushExcessBuffers);
        CVPixelBufferPoolRelease(VCPixelBufferPoolEntries[destinationIndex].pool);
    }

    VCPixelBufferPoolEntries[destinationIndex] = (VCPixelBufferPoolEntry){
        .width = width,
        .height = height,
        .pixelFormat = pixelFormat,
        .pool = createdPool,
        .lastUse = ++VCPixelBufferPoolUseCounter,
    };
    return createdPool;
}

CVPixelBufferRef VCCopyPixelBufferApplyingOrientation(CVPixelBufferRef source,
                                                       NSInteger clockwiseRotation,
                                                       BOOL mirrorHorizontally) {
    if (!source) return NULL;
    NSInteger rotation = ((clockwiseRotation % 360) + 360) % 360;
    if (rotation != 90 && rotation != 180 && rotation != 270) rotation = 0;
    if (rotation == 0 && !mirrorHorizontally) return CVPixelBufferRetain(source);

    CGImagePropertyOrientation orientation = kCGImagePropertyOrientationUp;
    switch (rotation) {
        case 90:
            orientation = kCGImagePropertyOrientationRight;
            break;
        case 180:
            orientation = kCGImagePropertyOrientationDown;
            break;
        case 270:
            orientation = kCGImagePropertyOrientationLeft;
            break;
        default:
            orientation = kCGImagePropertyOrientationUp;
            break;
    }

    CIImage *inputImage = [CIImage imageWithCVPixelBuffer:source];
    if (!inputImage) return NULL;
    CIImage *orientedImage = [inputImage imageByApplyingCGOrientation:orientation];
    if (!orientedImage) return NULL;
    CGRect extent = CGRectIntegral(orientedImage.extent);
    if (CGRectIsEmpty(extent) || extent.size.width > 8192.0 ||
        extent.size.height > 8192.0) {
        return NULL;
    }
    if (extent.origin.x != 0.0 || extent.origin.y != 0.0) {
        orientedImage = [orientedImage imageByApplyingTransform:
            CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
        extent.origin = CGPointZero;
    }
    if (mirrorHorizontally) {
        // Mirror after rotation so the switch always means horizontal mirror
        // in the final displayed coordinate system, independent of rotation.
        orientedImage = [orientedImage imageByApplyingTransform:
            CGAffineTransformMake(-1.0, 0.0, 0.0, 1.0, extent.size.width, 0.0)];
        extent = CGRectIntegral(orientedImage.extent);
        if (CGRectIsEmpty(extent)) return NULL;
        if (extent.origin.x != 0.0 || extent.origin.y != 0.0) {
            orientedImage = [orientedImage imageByApplyingTransform:
                CGAffineTransformMakeTranslation(-extent.origin.x, -extent.origin.y)];
            extent.origin = CGPointZero;
        }
    }

    size_t width = (size_t)extent.size.width;
    size_t height = (size_t)extent.size.height;
    CVPixelBufferRef destination = NULL;
    os_unfair_lock_lock(&VCFrameStateLock);
    CVPixelBufferPoolRef pool = VCLockedPixelBufferPool(width,
                                                        height,
                                                        kCVPixelFormatType_32BGRA);
    CVReturn result = pool
        ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            VCBoundedPixelBufferAllocationAttributes(),
            &destination)
        : kCVReturnInvalidArgument;
    os_unfair_lock_unlock(&VCFrameStateLock);
    if (result != kCVReturnSuccess || !destination) return NULL;

    CIContext *context = VCSharedOrientationContext();
    CGColorSpaceRef colorSpace = VCSharedDeviceRGBColorSpace();
    if (!context || !colorSpace) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    [context render:orientedImage
      toCVPixelBuffer:destination
               bounds:CGRectMake(0, 0, width, height)
           colorSpace:colorSpace];
    return destination;
}

static CVPixelBufferRef VCCopyBGRAStorage(CVPixelBufferRef source,
                                          BOOL allowRetainedBGRA) {
    if (!source) return NULL;
    if (allowRetainedBGRA &&
        CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA) {
        return CVPixelBufferRetain(source);
    }

    size_t width = CVPixelBufferGetWidth(source);
    size_t height = CVPixelBufferGetHeight(source);
    if (width == 0 || height == 0 || width > 8192 || height > 8192) return NULL;
    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    if (!image) return NULL;

    CVPixelBufferRef destination = NULL;
    os_unfair_lock_lock(&VCFrameStateLock);
    CVPixelBufferPoolRef pool = VCLockedPixelBufferPool(width,
                                                        height,
                                                        kCVPixelFormatType_32BGRA);
    CVReturn result = pool
        ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            VCBoundedPixelBufferAllocationAttributes(),
            &destination)
        : kCVReturnInvalidArgument;
    os_unfair_lock_unlock(&VCFrameStateLock);
    if (result != kCVReturnSuccess || !destination) return NULL;

    CIContext *context = VCSharedOrientationContext();
    CGColorSpaceRef colorSpace = VCSharedDeviceRGBColorSpace();
    if (!context || !colorSpace) {
        CVPixelBufferRelease(destination);
        return NULL;
    }
    [context render:image
      toCVPixelBuffer:destination
               bounds:CGRectMake(0, 0, width, height)
           colorSpace:colorSpace];
    return destination;
}

CVPixelBufferRef VCCopyDisplayPixelBuffer(CVPixelBufferRef source) {
    return VCCopyBGRAStorage(source, YES);
}

CVPixelBufferRef VCCopyShareablePixelBuffer(CVPixelBufferRef source) {
    // Always copy, including BGRA input. Decoder-owned IOSurfaces can expose a
    // nonzero ID while remaining non-global, which makes IOSurfaceLookup fail
    // in sandboxed consumers. The destination pool requests global storage.
    return VCCopyBGRAStorage(source, NO);
}

void VCResetFrameConverterCache(void) {
    VCFlushFrameConverterCaches(NO);
}

void VCFlushFrameConverterCaches(BOOL releasePoolsAndSession) {
    // Conversion releases the state lock before waiting for the session lock,
    // so this ordering cannot deadlock with an in-flight transfer.
    os_unfair_lock_lock(&VCPixelTransferSessionLock);
    os_unfair_lock_lock(&VCFrameStateLock);
    VCLockedClearConvertedFrames();
    if (releasePoolsAndSession) {
        VCLockedReleasePixelBufferPools();
    }
    os_unfair_lock_unlock(&VCFrameStateLock);
    if (releasePoolsAndSession && VCTransferSession) {
        VTPixelTransferSessionInvalidate(VCTransferSession);
        CFRelease(VCTransferSession);
        VCTransferSession = NULL;
    }
    os_unfair_lock_unlock(&VCPixelTransferSessionLock);
    if (releasePoolsAndSession && VCOrientationContext) {
        [VCOrientationContext clearCaches];
    }
}

CVPixelBufferRef VCCopyPixelBufferMatchingTemplate(CVPixelBufferRef source,
                                                    CVPixelBufferRef templateBuffer,
                                                    BOOL aspectFill) {
    return VCCopyPixelBufferMatchingTemplateAndDescription(source,
                                                            templateBuffer,
                                                            aspectFill,
                                                            NULL,
                                                            NULL);
}

CVPixelBufferRef VCCopyStablePixelBuffer(CVPixelBufferRef source) {
    if (!source) return NULL;
    // Even when the source already has the requested format, the transfer
    // path allocates different backing storage. This lets the caller release
    // its IOSurface use-count lease immediately after this synchronous copy.
    return VCCopyPixelBufferMatchingTemplateAndDescription(source,
                                                            source,
                                                            YES,
                                                            NULL,
                                                            NULL);
}

static CVPixelBufferRef VCCopyPixelBufferMatchingTemplateAndDescription(
    CVPixelBufferRef source,
    CVPixelBufferRef templateBuffer,
    BOOL aspectFill,
    CMFormatDescriptionRef templateDescription,
    CMVideoFormatDescriptionRef *replacementDescriptionOut) {
    if (!source || !templateBuffer) return NULL;
    if (replacementDescriptionOut) *replacementDescriptionOut = NULL;

    size_t width = CVPixelBufferGetWidth(templateBuffer);
    size_t height = CVPixelBufferGetHeight(templateBuffer);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(templateBuffer);
    if (width == 0 || height == 0 || !VCIsSupportedReplacementPixelFormat(pixelFormat)) {
        return NULL;
    }

    uint64_t conversionStarted = mach_continuous_time();
    CVPixelBufferRef destination = NULL;
    os_unfair_lock_lock(&VCFrameStateLock);

    destination = VCLockedCopyConvertedFrame(source,
                                              width,
                                              height,
                                              pixelFormat,
                                              aspectFill,
                                              templateDescription,
                                              replacementDescriptionOut);
    if (destination) {
        os_unfair_lock_unlock(&VCFrameStateLock);
        return destination;
    }

    CVPixelBufferPoolRef pool = VCLockedPixelBufferPool(width, height, pixelFormat);
    CVReturn result = pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                                kCFAllocatorDefault,
                                pool,
                                VCBoundedPixelBufferAllocationAttributes(),
                                &destination)
                           : kCVReturnInvalidArgument;
    os_unfair_lock_unlock(&VCFrameStateLock);
    if (result != kCVReturnSuccess || !destination) {
        return NULL;
    }

    // Destination color-space and clean-aperture attachments can influence the
    // transfer. Install the camera template metadata before converting pixels.
    CVBufferPropagateAttachments(templateBuffer, destination);
    BOOL ownsTransferLane = os_unfair_lock_trylock(&VCPixelTransferSessionLock);
    if (!ownsTransferLane) {
        // Camera graphs commonly fan one frame into preview, recording and
        // metadata consumers. If another node is already converting, reuse the
        // newest fully converted replacement for this exact target instead of
        // blocking emitSampleBuffer and allowing the physical frame through.
        os_unfair_lock_lock(&VCFrameStateLock);
        CVPixelBufferRef ready = VCLockedCopyConvertedFrame(source,
                                                             width,
                                                             height,
                                                             pixelFormat,
                                                             aspectFill,
                                                             templateDescription,
                                                             replacementDescriptionOut);
        if (!ready) {
            ready = VCLockedCopyMostRecentConvertedFrame(width,
                                                          height,
                                                          pixelFormat,
                                                          aspectFill,
                                                          templateDescription,
                                                          replacementDescriptionOut);
        }
        os_unfair_lock_unlock(&VCFrameStateLock);
        if (ready) {
            CVPixelBufferRelease(destination);
            return ready;
        }
        os_unfair_lock_lock(&VCPixelTransferSessionLock);
    }
    uint64_t sessionAcquired = mach_continuous_time();

    // A sibling output can finish the same conversion while this thread is
    // allocating. Recheck after acquiring the sole session lane and reuse the
    // cached result rather than running VideoToolbox twice.
    os_unfair_lock_lock(&VCFrameStateLock);
    CVPixelBufferRef raced = VCLockedCopyConvertedFrame(source,
                                                         width,
                                                         height,
                                                         pixelFormat,
                                                         aspectFill,
                                                         templateDescription,
                                                         replacementDescriptionOut);
    os_unfair_lock_unlock(&VCFrameStateLock);
    if (raced) {
        os_unfair_lock_unlock(&VCPixelTransferSessionLock);
        CVPixelBufferRelease(destination);
        return raced;
    }

    VTPixelTransferSessionRef session = VCLockedTransferSession();
    OSStatus status = kVTPixelTransferNotSupportedErr;
    if (session) {
        CFStringRef scalingMode = aspectFill ? kVTScalingMode_Trim : kVTScalingMode_Letterbox;
        VTSessionSetProperty(session, kVTPixelTransferPropertyKey_ScalingMode, scalingMode);
        status = VTPixelTransferSessionTransferImage(session, source, destination);
    }
    uint64_t transferFinished = mach_continuous_time();
    if (status != noErr) {
        os_unfair_lock_unlock(&VCPixelTransferSessionLock);
        VCLogSlowPixelTransfer(conversionStarted,
                               sessionAcquired,
                               transferFinished,
                               width,
                               height,
                               pixelFormat);
        CVPixelBufferRelease(destination);
        return NULL;
    }

    CMVideoFormatDescriptionRef replacementDescription = NULL;
    if (templateDescription) {
        if (CMVideoFormatDescriptionMatchesImageBuffer(
                (CMVideoFormatDescriptionRef)templateDescription,
                destination)) {
            replacementDescription =
                (CMVideoFormatDescriptionRef)CFRetain(templateDescription);
        } else {
            status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                   destination,
                                                                   &replacementDescription);
        }
        if (status != noErr || !replacementDescription) {
            if (replacementDescription) CFRelease(replacementDescription);
            os_unfair_lock_unlock(&VCPixelTransferSessionLock);
            CVPixelBufferRelease(destination);
            return NULL;
        }
    }

    os_unfair_lock_lock(&VCFrameStateLock);
    VCLockedStoreConvertedFrame(source,
                                width,
                                height,
                                pixelFormat,
                                aspectFill,
                                templateDescription,
                                replacementDescription,
                                destination);
    if (replacementDescriptionOut && replacementDescription) {
        *replacementDescriptionOut =
            (CMVideoFormatDescriptionRef)CFRetain(replacementDescription);
    }
    os_unfair_lock_unlock(&VCFrameStateLock);
    if (replacementDescription) CFRelease(replacementDescription);
    os_unfair_lock_unlock(&VCPixelTransferSessionLock);
    VCLogSlowPixelTransfer(conversionStarted,
                           sessionAcquired,
                           transferFinished,
                           width,
                           height,
                           pixelFormat);

    return destination;
}

CMSampleBufferRef VCCopyReplacementSampleBuffer(CMSampleBufferRef original,
                                                 CVPixelBufferRef source,
                                                 BOOL aspectFill,
                                                 NSInteger preferredFPS) {
    if (!original || !source) return NULL;

    CMFormatDescriptionRef originalDescription = CMSampleBufferGetFormatDescription(original);
    if (!originalDescription || CMFormatDescriptionGetMediaType(originalDescription) != kCMMediaType_Video) {
        return NULL;
    }

    CVPixelBufferRef templateBuffer = CMSampleBufferGetImageBuffer(original);
    if (!templateBuffer) return NULL;
    OSType templatePixelFormat = CVPixelBufferGetPixelFormatType(templateBuffer);
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(
        (CMVideoFormatDescriptionRef)originalDescription);
    if (!VCIsSupportedReplacementPixelFormat(templatePixelFormat) ||
        CMFormatDescriptionGetMediaSubType(originalDescription) != templatePixelFormat ||
        dimensions.width <= 0 || dimensions.height <= 0 ||
        (size_t)dimensions.width != CVPixelBufferGetWidth(templateBuffer) ||
        (size_t)dimensions.height != CVPixelBufferGetHeight(templateBuffer)) {
        return NULL;
    }

    CMVideoFormatDescriptionRef replacementDescription = NULL;
    CVPixelBufferRef replacementBuffer = VCCopyPixelBufferMatchingTemplateAndDescription(
        source,
        templateBuffer,
        aspectFill,
        originalDescription,
        &replacementDescription);
    if (!replacementBuffer) return NULL;
    if (!replacementDescription) {
        CVPixelBufferRelease(replacementBuffer);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, (int32_t)MAX(1, preferredFPS)),
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleTimingInfo originalTiming;
    if (CMSampleBufferGetSampleTimingInfo(original, 0, &originalTiming) == noErr) {
        timing = originalTiming;
        if (!CMTIME_IS_VALID(timing.duration) || CMTIME_IS_INDEFINITE(timing.duration)) {
            timing.duration = CMTimeMake(1, (int32_t)MAX(1, preferredFPS));
        }
    }

    CMSampleBufferRef replacement = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                                replacementBuffer,
                                                                replacementDescription,
                                                                &timing,
                                                                &replacement);
    CFRelease(replacementDescription);
    CVPixelBufferRelease(replacementBuffer);
    if (status != noErr || !replacement) return NULL;

    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault,
                                                                 original,
                                                                 kCMAttachmentMode_ShouldPropagate);
    if (attachments) {
        CMSetAttachments(replacement, attachments, kCMAttachmentMode_ShouldPropagate);
        CFRelease(attachments);
    }

    CFArrayRef originalSampleAttachments = CMSampleBufferGetSampleAttachmentsArray(original, false);
    CFArrayRef replacementSampleAttachments = CMSampleBufferGetSampleAttachmentsArray(replacement, true);
    if (originalSampleAttachments && replacementSampleAttachments &&
        CFArrayGetCount(originalSampleAttachments) > 0 &&
        CFArrayGetCount(replacementSampleAttachments) > 0) {
        CFDictionaryRef sourceDictionary = CFArrayGetValueAtIndex(originalSampleAttachments, 0);
        CFMutableDictionaryRef destinationDictionary =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(replacementSampleAttachments, 0);
        if (sourceDictionary && destinationDictionary) {
            CFDictionaryApplyFunction(sourceDictionary,
                                      VCCopyDictionaryEntry,
                                      destinationDictionary);
        }
    }
    return replacement;
}
