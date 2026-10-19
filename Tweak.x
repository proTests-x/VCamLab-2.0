#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ARKit/ARKit.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <objc/runtime.h>
#import <os/lock.h>

#import "VCAudioSampleConverter.h"
#import "VCFrameConverter.h"
#import "VCPreferences.h"
#import "VCSharedMediaBus.h"
#import "VCSharedMediaProtocol.h"
#import "VCStreamCoordinator.h"

static char VCOutputProxyAssociationKey;
static char VCPreviewOverlayAssociationKey;
static char VCPreviewTargetAssociationKey;
static char VCPreviewDisplayLinkAssociationKey;
static char VCPhotoPixelBufferAssociationKey;
static char VCPhotoPreviewPixelBufferAssociationKey;
static char VCPhotoSourceSnapshotAssociationKey;
static char VCPhotoReplacementModeAssociationKey;
static char VCPhotoFileDataAssociationKey;
static char VCARFramePixelBufferAssociationKey;
static dispatch_once_t VCPhotoJPEGFallbackLogToken;
static dispatch_once_t VCPhotoMetadataFailureLogToken;
static dispatch_once_t VCStreamMonitoringToken;
static char VCTargetSessionActiveAssociationKey;
static dispatch_queue_t VCTargetSessionStateQueue;
static dispatch_source_t VCTargetSessionHeartbeatTimer;
static NSUInteger VCTargetSessionActiveCount;

static BOOL VCApplicationReplacementAllowed(void) {
    return [VCPreferences.sharedPreferences isCurrentProcessSelected];
}

static void VCEnsureStreamMonitoring(void) {
    dispatch_once(&VCStreamMonitoringToken, ^{
        [[VCStreamCoordinator sharedCoordinator] startMonitoring];
    });
}

static dispatch_queue_t VCTargetCaptureQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCTargetSessionStateQueue = dispatch_queue_create(
            "com.murkaska.virtualcampro.target-capture",
            DISPATCH_QUEUE_SERIAL);
    });
    return VCTargetSessionStateQueue;
}

static void VCEnsureTargetCaptureHeartbeatLocked(void) {
    if (VCTargetSessionHeartbeatTimer) return;
    VCTargetSessionHeartbeatTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        VCTargetCaptureQueue());
    dispatch_source_set_timer(VCTargetSessionHeartbeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC,
                              100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(VCTargetSessionHeartbeatTimer, ^{
        VCSetTargetCaptureActive(VCTargetSessionActiveCount > 0 &&
                                 VCApplicationReplacementAllowed());
    });
    dispatch_resume(VCTargetSessionHeartbeatTimer);
}

static void VCTargetCameraConsumerDidStart(id consumer) {
    if (!consumer) return;
    [VCPreferences.sharedPreferences reload];
    if (!VCApplicationReplacementAllowed()) return;
    @synchronized (consumer) {
        if ([objc_getAssociatedObject(consumer,
                                      &VCTargetSessionActiveAssociationKey) boolValue]) {
            return;
        }
        objc_setAssociatedObject(consumer,
                                 &VCTargetSessionActiveAssociationKey,
                                 @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    dispatch_async(VCTargetCaptureQueue(), ^{
        VCTargetSessionActiveCount++;
        VCEnsureTargetCaptureHeartbeatLocked();
        VCSetTargetCaptureActive(YES);
    });
}

static void VCTargetCameraConsumerDidStop(id consumer) {
    if (!consumer) return;
    @synchronized (consumer) {
        if (![objc_getAssociatedObject(consumer,
                                       &VCTargetSessionActiveAssociationKey) boolValue]) {
            return;
        }
        objc_setAssociatedObject(consumer,
                                 &VCTargetSessionActiveAssociationKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    dispatch_async(VCTargetCaptureQueue(), ^{
        if (VCTargetSessionActiveCount > 0) VCTargetSessionActiveCount--;
        VCSetTargetCaptureActive(VCTargetSessionActiveCount > 0);
    });
}

#pragma mark - Selected application camera activity

%hook AVCaptureSession

- (void)startRunning {
    %orig;
    if (self.isRunning) VCTargetCameraConsumerDidStart(self);
}

- (void)stopRunning {
    %orig;
    VCTargetCameraConsumerDidStop(self);
}

%end

%hook ARSession

- (void)runWithConfiguration:(ARConfiguration *)configuration
                     options:(ARSessionRunOptions)options {
    %orig(configuration, options);
    VCTargetCameraConsumerDidStart(self);
}

- (void)pause {
    %orig;
    VCTargetCameraConsumerDidStop(self);
}

%end

static CFStringRef const VCReplacedSampleAttachmentKey =
    CFSTR(VC_SYSTEM_REPLACEMENT_ATTACHMENT_KEY);

static BOOL VCSampleWasReplacedBySystem(CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer) return NO;
    if (CMGetAttachment(sampleBuffer,
                        VCReplacedSampleAttachmentKey,
                        NULL) == kCFBooleanTrue) {
        return YES;
    }
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    return pixelBuffer &&
        CVBufferGetAttachment(pixelBuffer,
                              VCReplacedSampleAttachmentKey,
                              NULL) == kCFBooleanTrue;
}

static CIContext *VCSharedCIContext(void) {
    static CIContext *context;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return context;
}

static CMSampleBufferRef VCCopyCurrentReplacement(
    CMSampleBufferRef original,
    VCApplicationVideoRuntimeEvent *runtimeEventOut,
    uint8_t *runtimeDetailOut) CF_RETURNS_RETAINED {
    if (runtimeEventOut) *runtimeEventOut = VCApplicationVideoRuntimeUnknown;
    if (runtimeDetailOut) *runtimeDetailOut = 0;
    if (!VCApplicationReplacementAllowed()) return NULL;
    VCStreamCoordinator *coordinator = [VCStreamCoordinator sharedCoordinator];
    // Suppress only for evidence attached to this exact sample. A global
    // mediaserverd heartbeat cannot prove that another capture session, node
    // subclass, or output path was replaced successfully.
    if (VCSampleWasReplacedBySystem(original)) {
        if (runtimeEventOut) {
            *runtimeEventOut = VCApplicationVideoRuntimeSystemReplacementObserved;
        }
        return NULL;
    }
    BOOL aspectFill = YES;
    NSInteger preferredFPS = 60;
    CVPixelBufferRef source = [coordinator copyLatestPixelBufferWithAspectFill:&aspectFill
                                                                 preferredFPS:&preferredFPS];
    if (!source) {
        if (runtimeEventOut) {
            *runtimeEventOut = VCApplicationVideoRuntimeSourceUnavailable;
        }
        if (runtimeDetailOut) {
            *runtimeDetailOut =
                (uint8_t)VCSharedVideoLastFailureReason();
        }
        return NULL;
    }
    CMSampleBufferRef replacement = VCCopyReplacementSampleBuffer(original,
                                                                   source,
                                                                   aspectFill,
                                                                   preferredFPS);
    VCReleaseSharedVideoPixelBuffer(source);
    if (runtimeEventOut) {
        *runtimeEventOut = replacement
            ? VCApplicationVideoRuntimeReplacementSucceeded
            : VCApplicationVideoRuntimeConversionFailed;
    }
    return replacement;
}

#pragma mark - AVCaptureVideoDataOutput compatibility path

@interface VCVideoDataOutputProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
    os_unfair_lock _stateLock;
    CVPixelBufferRef _latestCompatibilityPixelBuffer;
    CFAbsoluteTime _latestCallbackTime;
    BOOL _outputPathActive;
}
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> originalDelegate;
- (CVPixelBufferRef _Nullable)copyRecentCompatibilityPixelBufferWithActivePath:
    (BOOL *)activePath CF_RETURNS_RETAINED;
@end


@implementation VCVideoDataOutputProxy

- (instancetype)init {
    self = [super init];
    if (self) _stateLock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
    return self;
}

- (void)recordCompatibilityPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef retained = pixelBuffer ? CVPixelBufferRetain(pixelBuffer) : NULL;
    CVPixelBufferRef retired = NULL;
    os_unfair_lock_lock(&_stateLock);
    retired = _latestCompatibilityPixelBuffer;
    _latestCompatibilityPixelBuffer = retained;
    _latestCallbackTime = CFAbsoluteTimeGetCurrent();
    _outputPathActive = YES;
    os_unfair_lock_unlock(&_stateLock);
    if (retired) CVPixelBufferRelease(retired);
}

- (CVPixelBufferRef)copyRecentCompatibilityPixelBufferWithActivePath:(BOOL *)activePath {
    CVPixelBufferRef result = NULL;
    CVPixelBufferRef stale = NULL;
    os_unfair_lock_lock(&_stateLock);
    BOOL recent = _outputPathActive && _latestCallbackTime > 0 &&
        CFAbsoluteTimeGetCurrent() - _latestCallbackTime <= 2.0;
    if (!recent && _outputPathActive) {
        stale = _latestCompatibilityPixelBuffer;
        _latestCompatibilityPixelBuffer = NULL;
        _latestCallbackTime = 0;
        _outputPathActive = NO;
    }
    if (activePath) *activePath = recent;
    if (recent && _latestCompatibilityPixelBuffer) {
        result = CVPixelBufferRetain(_latestCompatibilityPixelBuffer);
    }
    os_unfair_lock_unlock(&_stateLock);
    if (stale) CVPixelBufferRelease(stale);
    return result;
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.originalDelegate respondsToSelector:selector]) return self.originalDelegate;
    return [super forwardingTargetForSelector:selector];
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
    if (![delegate respondsToSelector:_cmd]) return;

    VCApplicationVideoRuntimeEvent runtimeEvent =
        VCApplicationVideoRuntimeUnknown;
    uint8_t runtimeDetail = 0;
    CMSampleBufferRef replacement = VCCopyCurrentReplacement(sampleBuffer,
                                                              &runtimeEvent,
                                                              &runtimeDetail);
    if (runtimeEvent != VCApplicationVideoRuntimeUnknown) {
        VCReportApplicationVideoRuntimeEvent(runtimeEvent, runtimeDetail);
    }
    [self recordCompatibilityPixelBuffer:
        replacement ? CMSampleBufferGetImageBuffer(replacement) : NULL];
    [delegate captureOutput:output
      didOutputSampleBuffer:replacement ?: sampleBuffer
             fromConnection:connection];
    if (replacement) CFRelease(replacement);
}

- (void)captureOutput:(AVCaptureOutput *)output
didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
    if ([delegate respondsToSelector:_cmd]) {
        [delegate captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)dealloc {
    if (_latestCompatibilityPixelBuffer) {
        CVPixelBufferRelease(_latestCompatibilityPixelBuffer);
    }
}

@end


%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!delegate) {
        objc_setAssociatedObject(self, &VCOutputProxyAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(nil, queue);
        return;
    }

    if ([delegate isKindOfClass:[VCVideoDataOutputProxy class]]) {
        %orig(delegate, queue);
        return;
    }

    VCEnsureStreamMonitoring();

    VCVideoDataOutputProxy *proxy = [VCVideoDataOutputProxy new];
    proxy.originalDelegate = delegate;
    objc_setAssociatedObject(self,
                             &VCOutputProxyAssociationKey,
                             proxy,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(proxy, queue);
    VCReportApplicationVideoRuntimeEvent(
        VCApplicationVideoRuntimeDelegateWrapped,
        0);
}

- (id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate {
    id actualDelegate = %orig;
    if ([actualDelegate isKindOfClass:[VCVideoDataOutputProxy class]]) {
        return [(VCVideoDataOutputProxy *)actualDelegate originalDelegate];
    }
    return actualDelegate;
}

%end

#pragma mark - AVCaptureAudioDataOutput automatic fallback

@interface VCAudioDataOutputProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureAudioDataOutputSampleBufferDelegate> originalDelegate;
@property (nonatomic, strong) VCAudioReplacementContext *replacementContext;
@end

static char VCAudioOutputProxyAssociationKey;

@implementation VCAudioDataOutputProxy

- (instancetype)init {
    self = [super init];
    if (self) _replacementContext = [VCAudioReplacementContext new];
    return self;
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if ([self.originalDelegate respondsToSelector:selector]) return self.originalDelegate;
    return [super forwardingTargetForSelector:selector];
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureAudioDataOutputSampleBufferDelegate> delegate = self.originalDelegate;
    if (![delegate respondsToSelector:_cmd]) return;
    CMSampleBufferRef replacement = !VCApplicationReplacementAllowed() ||
        VCSampleWasReplacedBySystem(sampleBuffer)
        ? NULL : VCCopyReplacementAudioSampleBuffer(sampleBuffer,
                                                     self.replacementContext);
    [delegate captureOutput:output
      didOutputSampleBuffer:replacement ?: sampleBuffer
             fromConnection:connection];
    if (replacement) CFRelease(replacement);
}

@end

static CVPixelBufferRef VCCopySessionCompatibilityPixelBuffer(
    AVCaptureSession *session,
    BOOL *activePath) CF_RETURNS_RETAINED {
    BOOL foundActivePath = NO;
    if (activePath) *activePath = NO;
    for (AVCaptureOutput *output in session.outputs) {
        if (![output isKindOfClass:AVCaptureVideoDataOutput.class]) continue;
        VCVideoDataOutputProxy *proxy =
            objc_getAssociatedObject(output, &VCOutputProxyAssociationKey);
        if (![proxy isKindOfClass:VCVideoDataOutputProxy.class]) continue;
        BOOL proxyActive = NO;
        CVPixelBufferRef pixelBuffer =
            [proxy copyRecentCompatibilityPixelBufferWithActivePath:&proxyActive];
        foundActivePath = foundActivePath || proxyActive;
        if (pixelBuffer) {
            if (activePath) *activePath = YES;
            return pixelBuffer;
        }
    }
    if (activePath) *activePath = foundActivePath;
    return NULL;
}

%hook AVCaptureAudioDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureAudioDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!delegate) {
        objc_setAssociatedObject(self,
                                 &VCAudioOutputProxyAssociationKey,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(nil, queue);
        return;
    }
    if ([delegate isKindOfClass:VCAudioDataOutputProxy.class]) {
        %orig(delegate, queue);
        return;
    }
    VCAudioDataOutputProxy *proxy = [VCAudioDataOutputProxy new];
    proxy.originalDelegate = delegate;
    objc_setAssociatedObject(self,
                             &VCAudioOutputProxyAssociationKey,
                             proxy,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(proxy, queue);
}

- (id<AVCaptureAudioDataOutputSampleBufferDelegate>)sampleBufferDelegate {
    id actual = %orig;
    return [actual isKindOfClass:VCAudioDataOutputProxy.class]
        ? [(VCAudioDataOutputProxy *)actual originalDelegate] : actual;
}
%end

#pragma mark - AVCaptureVideoPreviewLayer compatibility path

@interface VCPreviewDisplayTarget : NSObject {
    CVPixelBufferRef _sharedPixelBufferLease;
    BOOL _hasLoggedDisplayState;
    BOOL _lastShouldDisplay;
}
@property (nonatomic, weak) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong, nullable) id displayedSurface;
- (void)displayLinkDidFire:(CADisplayLink *)displayLink;
@end


@implementation VCPreviewDisplayTarget

- (void)replaceSharedPixelBufferLease:(CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef retired = _sharedPixelBufferLease;
    _sharedPixelBufferLease = pixelBuffer;
    if (retired) VCReleaseSharedVideoPixelBuffer(retired);
}

- (void)displayLinkDidFire:(CADisplayLink *)displayLink {
    AVCaptureVideoPreviewLayer *previewLayer = self.previewLayer;
    if (!previewLayer) {
        [displayLink invalidate];
        return;
    }

    CALayer *overlay = objc_getAssociatedObject(previewLayer, &VCPreviewOverlayAssociationKey);
    if (!overlay) return;
    if (!VCApplicationReplacementAllowed()) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.contents = nil;
        overlay.hidden = YES;
        [CATransaction commit];
        self.displayedSurface = nil;
        [self replaceSharedPixelBufferLease:NULL];
        return;
    }

    VCStreamCoordinator *coordinator = [VCStreamCoordinator sharedCoordinator];
    BOOL aspectFill = YES;
    NSInteger preferredFPS = 60;
    BOOL outputPathActive = NO;
    CVPixelBufferRef compatibilityBuffer =
        VCCopySessionCompatibilityPixelBuffer(previewLayer.session, &outputPathActive);
    CVPixelBufferRef pixelBuffer =
        [coordinator copyLatestPixelBufferWithAspectFill:&aspectFill
                                             preferredFPS:&preferredFPS];
    BOOL usingSharedFrame = pixelBuffer != NULL;
    BOOL usingCompatibilityFrame = NO;
    if (usingSharedFrame) {
        if (compatibilityBuffer) CVPixelBufferRelease(compatibilityBuffer);
    } else if (outputPathActive && compatibilityBuffer) {
        pixelBuffer = VCCopyDisplayPixelBuffer(compatibilityBuffer);
        CVPixelBufferRelease(compatibilityBuffer);
        usingCompatibilityFrame = pixelBuffer != NULL;
        preferredFPS = coordinator.preferredFPS;
    } else if (compatibilityBuffer) {
        CVPixelBufferRelease(compatibilityBuffer);
    }
    NSInteger maximumDisplayFPS = MAX(1, UIScreen.mainScreen.maximumFramesPerSecond);
    NSInteger displayFPS = pixelBuffer ? MIN(preferredFPS, maximumDisplayFPS) : 1;
    if (displayLink.preferredFramesPerSecond != displayFPS) {
        displayLink.preferredFramesPerSecond = displayFPS;
    }
    IOSurfaceRef displaySurface = pixelBuffer
        ? CVPixelBufferGetIOSurface(pixelBuffer)
        : NULL;
    BOOL shouldDisplay = displaySurface != NULL;
    if (!_hasLoggedDisplayState || _lastShouldDisplay != shouldDisplay) {
        _hasLoggedDisplayState = YES;
        _lastShouldDisplay = shouldDisplay;
        NSLog(@"[VirtualCamPro] Preview %@ in %@ (shared=%@, compatibility=%@, failure=%u)",
              shouldDisplay ? @"active" : @"waiting for source",
              NSProcessInfo.processInfo.processName,
              usingSharedFrame ? @"YES" : @"NO",
              usingCompatibilityFrame ? @"YES" : @"NO",
              shouldDisplay || outputPathActive
                  ? 0
                  : (unsigned int)VCSharedVideoLastFailureReason());
    }
    VCReportApplicationVideoRuntimeEvent(
        shouldDisplay
            ? VCApplicationVideoRuntimePreviewFrameDisplayed
            : VCApplicationVideoRuntimePreviewSourceUnavailable,
        shouldDisplay || outputPathActive
            ? 0
            : (uint8_t)VCSharedVideoLastFailureReason());

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!CGRectEqualToRect(overlay.frame, previewLayer.bounds)) overlay.frame = previewLayer.bounds;
    // Prefer the continuously published SpringBoard surface. If it is briefly
    // unavailable, display the application's converted compatibility frame
    // with complete bounds instead of applying a second crop.
    overlay.contentsGravity = usingCompatibilityFrame
        ? kCAGravityResizeAspect
        : (aspectFill ? kCAGravityResizeAspectFill : kCAGravityResizeAspect);
    if (shouldDisplay) {
        id surfaceObject = (__bridge id)displaySurface;
        if (self.displayedSurface != surfaceObject) {
            self.displayedSurface = surfaceObject;
            overlay.contents = surfaceObject;
        }
        overlay.hidden = NO;
    } else {
        self.displayedSurface = nil;
        overlay.contents = nil;
        overlay.hidden = YES;
    }
    [CATransaction commit];
    if (usingSharedFrame && pixelBuffer) {
        // CoreAnimation consumes the IOSurface asynchronously. Transfer the
        // cross-process use-count lease to the display target and retire it
        // only after the next surface has been committed.
        [self replaceSharedPixelBufferLease:pixelBuffer];
    } else {
        [self replaceSharedPixelBufferLease:NULL];
        if (pixelBuffer) CVPixelBufferRelease(pixelBuffer);
    }
}

- (void)dealloc {
    [self replaceSharedPixelBufferLease:NULL];
}

@end

static void VCEnsurePreviewOverlay(AVCaptureVideoPreviewLayer *previewLayer) {
    if (!previewLayer) return;
    VCEnsureStreamMonitoring();
    if (![NSThread isMainThread]) {
        __weak AVCaptureVideoPreviewLayer *weakLayer = previewLayer;
        dispatch_async(dispatch_get_main_queue(), ^{
            VCEnsurePreviewOverlay(weakLayer);
        });
        return;
    }

    CALayer *overlay = objc_getAssociatedObject(previewLayer,
                                                 &VCPreviewOverlayAssociationKey);
    if (overlay) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.frame = previewLayer.bounds;
        [CATransaction commit];
        return;
    }

    overlay = [CALayer layer];
    overlay.frame = previewLayer.bounds;
    overlay.zPosition = CGFLOAT_MAX;
    overlay.masksToBounds = YES;
    overlay.hidden = YES;
    [previewLayer addSublayer:overlay];
    objc_setAssociatedObject(previewLayer,
                             &VCPreviewOverlayAssociationKey,
                             overlay,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    VCPreviewDisplayTarget *target = [VCPreviewDisplayTarget new];
    target.previewLayer = previewLayer;
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:target
                                                             selector:@selector(displayLinkDidFire:)];
    VCStreamCoordinator *coordinator = [VCStreamCoordinator sharedCoordinator];
    displayLink.preferredFramesPerSecond = coordinator.isReplacementActive
        ? MIN(coordinator.preferredFPS,
              MAX(1, UIScreen.mainScreen.maximumFramesPerSecond))
        : 1;
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(previewLayer,
                             &VCPreviewTargetAssociationKey,
                             target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(previewLayer,
                             &VCPreviewDisplayLinkAssociationKey,
                             displayLink,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[VirtualCamPro] Preview overlay installed in %@",
          NSProcessInfo.processInfo.processName);
    VCReportApplicationVideoRuntimeEvent(
        VCApplicationVideoRuntimePreviewOverlayInstalled,
        0);
}


%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *result = %orig;
    VCEnsurePreviewOverlay(result);
    return result;
}

- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *result = %orig;
    VCEnsurePreviewOverlay(result);
    return result;
}

- (void)setSession:(AVCaptureSession *)session {
    %orig;
    VCEnsurePreviewOverlay(self);
}

- (void)layoutSublayers {
    %orig;
    VCEnsurePreviewOverlay(self);
}

%end

#pragma mark - AVCapturePhoto compatibility path

@interface VCPixelBufferBox : NSObject {
    CVPixelBufferRef _pixelBuffer;
}
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@property (nonatomic, readonly) CVPixelBufferRef pixelBuffer;
@end


@implementation VCPixelBufferBox
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    self = [super init];
    if (self) _pixelBuffer = pixelBuffer ? CVPixelBufferRetain(pixelBuffer) : NULL;
    return self;
}
- (CVPixelBufferRef)pixelBuffer { return _pixelBuffer; }
- (void)dealloc { if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer); }
@end

#pragma mark - ARKit captured image compatibility path

%hook ARFrame

- (CVPixelBufferRef)capturedImage {
    CVPixelBufferRef original = %orig;
    if (!original || !VCApplicationReplacementAllowed()) return original;

    VCPixelBufferBox *cached = objc_getAssociatedObject(
        self,
        &VCARFramePixelBufferAssociationKey);
    if (cached.pixelBuffer) return cached.pixelBuffer;

    VCEnsureStreamMonitoring();
    BOOL aspectFill = YES;
    NSInteger preferredFPS = 60;
    CVPixelBufferRef source = [[VCStreamCoordinator sharedCoordinator]
        copyLatestPixelBufferWithAspectFill:&aspectFill
                               preferredFPS:&preferredFPS];
    if (!source) return original;
    CVPixelBufferRef replacement = VCCopyPixelBufferMatchingTemplate(source,
                                                                      original,
                                                                      aspectFill);
    VCReleaseSharedVideoPixelBuffer(source);
    if (!replacement) return original;

    VCPixelBufferBox *box = [[VCPixelBufferBox alloc]
        initWithPixelBuffer:replacement];
    CVPixelBufferRelease(replacement);
    objc_setAssociatedObject(self,
                             &VCARFramePixelBufferAssociationKey,
                             box,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    VCReportApplicationVideoRuntimeEvent(
        VCApplicationVideoRuntimeReplacementSucceeded,
        0);
    return box.pixelBuffer ?: original;
}

%end

@interface VCPhotoSourceSnapshot : NSObject {
    CVPixelBufferRef _pixelBuffer;
}
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          aspectFill:(BOOL)aspectFill
                         jpegQuality:(CGFloat)jpegQuality;
@property (nonatomic, readonly) CVPixelBufferRef pixelBuffer;
@property (nonatomic, readonly) BOOL aspectFill;
@property (nonatomic, readonly) CGFloat jpegQuality;
@end

@implementation VCPhotoSourceSnapshot
- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          aspectFill:(BOOL)aspectFill
                         jpegQuality:(CGFloat)jpegQuality {
    self = [super init];
    if (self) {
        _pixelBuffer = pixelBuffer ? CVPixelBufferRetain(pixelBuffer) : NULL;
        _aspectFill = aspectFill;
        _jpegQuality = jpegQuality;
    }
    return self;
}
- (CVPixelBufferRef)pixelBuffer { return _pixelBuffer; }
- (void)dealloc { if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer); }
@end

static VCPhotoSourceSnapshot *VCPhotoSnapshotLocked(AVCapturePhoto *photo) {
    VCPhotoSourceSnapshot *snapshot =
        objc_getAssociatedObject(photo, &VCPhotoSourceSnapshotAssociationKey);
    if (snapshot) return snapshot;

    VCStreamCoordinator *coordinator = [VCStreamCoordinator sharedCoordinator];
    BOOL aspectFill = YES;
    CVPixelBufferRef source = [coordinator copyLatestPixelBufferWithAspectFill:&aspectFill
                                                                  preferredFPS:NULL];
    if (!source) return nil;
    CVPixelBufferRef stableSource = VCCopyStablePixelBuffer(source);
    VCReleaseSharedVideoPixelBuffer(source);
    if (!stableSource) return nil;
    snapshot = [[VCPhotoSourceSnapshot alloc] initWithPixelBuffer:stableSource
                                                       aspectFill:aspectFill
                                                      jpegQuality:coordinator.jpegQuality];
    CVPixelBufferRelease(stableSource);
    objc_setAssociatedObject(photo,
                             &VCPhotoSourceSnapshotAssociationKey,
                             snapshot,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return snapshot;
}

typedef NS_ENUM(NSInteger, VCPhotoReplacementMode) {
    VCPhotoReplacementModeOriginal = 0,
    VCPhotoReplacementModeApplicationFallback = 1,
};

static VCPhotoReplacementMode VCReplacementModeForPhoto(AVCapturePhoto *photo) {
    @synchronized (photo) {
        NSNumber *cachedMode =
            objc_getAssociatedObject(photo, &VCPhotoReplacementModeAssociationKey);
        if (cachedMode) return (VCPhotoReplacementMode)cachedMode.integerValue;

        VCStreamCoordinator *coordinator = [VCStreamCoordinator sharedCoordinator];
        VCPhotoReplacementMode mode = VCPhotoReplacementModeOriginal;
        // AVCapturePhoto does not expose a stable session identifier that can
        // be correlated with a mediaserverd BW node. Prefer a conservative
        // per-photo fallback over suppressing this path because an unrelated
        // session emitted a global heartbeat. If the system layer already
        // replaced the photo, this reuses the same source and remains fail-open.
        if (VCApplicationReplacementAllowed() && coordinator.isReplacementActive) {
            mode = VCPhotoSnapshotLocked(photo).pixelBuffer
                ? VCPhotoReplacementModeApplicationFallback
                : VCPhotoReplacementModeOriginal;
        }
        objc_setAssociatedObject(photo,
                                 &VCPhotoReplacementModeAssociationKey,
                                 @(mode),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return mode;
    }
}

static BOOL VCPhotoHasCompatibilityReplacement(AVCapturePhoto *photo) {
    return VCReplacementModeForPhoto(photo) == VCPhotoReplacementModeApplicationFallback;
}

static BOOL VCPhotoUsesReplacement(AVCapturePhoto *photo) {
    return VCReplacementModeForPhoto(photo) != VCPhotoReplacementModeOriginal;
}


static CVPixelBufferRef VCPhotoReplacementPixelBuffer(AVCapturePhoto *photo,
                                                       CVPixelBufferRef templateBuffer,
                                                       const void *associationKey) {
    if (!VCPhotoHasCompatibilityReplacement(photo)) return NULL;
    @synchronized (photo) {
        VCPixelBufferBox *existingBox = objc_getAssociatedObject(photo, associationKey);
        if (existingBox.pixelBuffer) {
            BOOL matchesTemplate = !templateBuffer ||
                (CVPixelBufferGetWidth(existingBox.pixelBuffer) == CVPixelBufferGetWidth(templateBuffer) &&
                 CVPixelBufferGetHeight(existingBox.pixelBuffer) == CVPixelBufferGetHeight(templateBuffer) &&
                 CVPixelBufferGetPixelFormatType(existingBox.pixelBuffer) ==
                     CVPixelBufferGetPixelFormatType(templateBuffer));
            if (matchesTemplate) return existingBox.pixelBuffer;
        }

        VCPhotoSourceSnapshot *snapshot = VCPhotoSnapshotLocked(photo);
        if (!snapshot.pixelBuffer) return NULL;
        CVPixelBufferRef replacement = templateBuffer
            ? VCCopyPixelBufferMatchingTemplate(snapshot.pixelBuffer,
                                                templateBuffer,
                                                snapshot.aspectFill)
            : CVPixelBufferRetain(snapshot.pixelBuffer);
        if (!replacement) return NULL;

        VCPixelBufferBox *box = [[VCPixelBufferBox alloc] initWithPixelBuffer:replacement];
        CVPixelBufferRelease(replacement);
        objc_setAssociatedObject(photo,
                                 associationKey,
                                 box,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return box.pixelBuffer;
    }
}

static CGImageRef VCCreatePhotoCGImage(CVPixelBufferRef pixelBuffer) CF_RETURNS_RETAINED {
    if (!pixelBuffer) return NULL;
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!image || CGRectIsEmpty(image.extent)) return NULL;
    return [VCSharedCIContext() createCGImage:image fromRect:image.extent];
}

static NSDictionary *VCPhotoPropertiesForReplacement(CGImageSourceRef source,
                                                       size_t index,
                                                       CGImageRef replacementImage) {
    NSDictionary *sourceProperties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
    NSMutableDictionary *properties = sourceProperties
        ? [sourceProperties mutableCopy]
        : [NSMutableDictionary dictionary];
    NSNumber *width = @(CGImageGetWidth(replacementImage));
    NSNumber *height = @(CGImageGetHeight(replacementImage));
    properties[(id)kCGImagePropertyPixelWidth] = width;
    properties[(id)kCGImagePropertyPixelHeight] = height;

    NSDictionary *sourceExif = properties[(id)kCGImagePropertyExifDictionary];
    if (sourceExif) {
        NSMutableDictionary *exif = [sourceExif mutableCopy];
        exif[(id)kCGImagePropertyExifPixelXDimension] = width;
        exif[(id)kCGImagePropertyExifPixelYDimension] = height;
        properties[(id)kCGImagePropertyExifDictionary] = exif;
    }
    return properties;
}

static BOOL VCPhotoDataPreservesAuthenticMetadata(NSData *candidateData,
                                                   NSDictionary *sourceProperties,
                                                   size_t expectedWidth,
                                                   size_t expectedHeight) {
    if (!candidateData || !sourceProperties) return NO;
    CGImageSourceRef candidateSource = CGImageSourceCreateWithData(
        (__bridge CFDataRef)candidateData,
        NULL);
    if (!candidateSource || CGImageSourceGetCount(candidateSource) == 0) {
        if (candidateSource) CFRelease(candidateSource);
        return NO;
    }
    NSDictionary *candidateProperties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(candidateSource, 0, NULL));
    CFRelease(candidateSource);
    if (!candidateProperties) return NO;
    NSNumber *candidateWidth = candidateProperties[(id)kCGImagePropertyPixelWidth];
    NSNumber *candidateHeight = candidateProperties[(id)kCGImagePropertyPixelHeight];
    if (candidateWidth.unsignedLongLongValue != expectedWidth ||
        candidateHeight.unsignedLongLongValue != expectedHeight) {
        return NO;
    }

    NSArray<NSArray *> *metadataPaths = @[
        @[(id)kCGImagePropertyTIFFDictionary, (id)kCGImagePropertyTIFFMake],
        @[(id)kCGImagePropertyTIFFDictionary, (id)kCGImagePropertyTIFFModel],
        @[(id)kCGImagePropertyTIFFDictionary, (id)kCGImagePropertyTIFFSoftware],
        @[(id)kCGImagePropertyExifDictionary, (id)kCGImagePropertyExifDateTimeOriginal],
        @[(id)kCGImagePropertyExifDictionary, (id)kCGImagePropertyExifLensMake],
        @[(id)kCGImagePropertyExifDictionary, (id)kCGImagePropertyExifLensModel],
    ];
    BOOL foundAuthenticDeviceIdentity = NO;
    for (NSArray *path in metadataPaths) {
        id dictionaryKey = path[0];
        id valueKey = path[1];
        NSDictionary *sourceDictionary = sourceProperties[dictionaryKey];
        NSDictionary *candidateDictionary = candidateProperties[dictionaryKey];
        id sourceValue = [sourceDictionary isKindOfClass:NSDictionary.class]
            ? sourceDictionary[valueKey]
            : nil;
        if (!sourceValue) continue;
        if ([dictionaryKey isEqual:(id)kCGImagePropertyTIFFDictionary] &&
            ([valueKey isEqual:(id)kCGImagePropertyTIFFMake] ||
             [valueKey isEqual:(id)kCGImagePropertyTIFFModel])) {
            foundAuthenticDeviceIdentity = YES;
        }
        id candidateValue = [candidateDictionary isKindOfClass:NSDictionary.class]
            ? candidateDictionary[valueKey]
            : nil;
        if (!candidateValue || ![candidateValue isEqual:sourceValue]) return NO;
    }

    NSDictionary *sourceMakerApple = sourceProperties[(id)kCGImagePropertyMakerAppleDictionary];
    if (sourceMakerApple.count > 0) {
        foundAuthenticDeviceIdentity = YES;
        NSDictionary *candidateMakerApple =
            candidateProperties[(id)kCGImagePropertyMakerAppleDictionary];
        if (![candidateMakerApple isEqualToDictionary:sourceMakerApple]) return NO;
    }
    NSDictionary *sourceGPS = sourceProperties[(id)kCGImagePropertyGPSDictionary];
    if (sourceGPS.count > 0) {
        NSDictionary *candidateGPS = candidateProperties[(id)kCGImagePropertyGPSDictionary];
        if (![candidateGPS isEqualToDictionary:sourceGPS]) return NO;
    }
    id sourceOrientation = sourceProperties[(id)kCGImagePropertyOrientation];
    id candidateOrientation = candidateProperties[(id)kCGImagePropertyOrientation];
    if (sourceOrientation && ![candidateOrientation isEqual:sourceOrientation]) return NO;
    return foundAuthenticDeviceIdentity;
}

static NSData *VCPhotoDataByReplacingPrimaryImage(NSData *originalData,
                                                   CGImageRef replacementImage,
                                                   CGFloat jpegQuality) {
    if (!originalData || !replacementImage) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)originalData, NULL);
    if (!source) return nil;

    CFStringRef sourceType = CGImageSourceGetType(source);
    size_t sourceImageCount = CGImageSourceGetCount(source);
    if (!sourceType || sourceImageCount == 0) {
        CFRelease(source);
        return nil;
    }
    NSDictionary *sourceProperties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    sourceProperties = sourceProperties ?: @{};

    NSMutableData *resultData = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)resultData,
        sourceType,
        1,
        NULL);
    if (destination) {
        NSDictionary *primaryProperties = VCPhotoPropertiesForReplacement(source,
                                                                            0,
                                                                            replacementImage);
        CGImageDestinationAddImage(destination,
                                   replacementImage,
                                   (__bridge CFDictionaryRef)primaryProperties);

        // Depth, disparity, semantic mattes, gain maps, and secondary images describe
        // the original physical scene. Reattaching them to a network replacement would
        // create internally contradictory (and potentially privacy-leaking) photo data.
        // Keep the real device/EXIF/GPS identity, but emit only the verified replacement.
        BOOL finalized = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        if (finalized && resultData.length > 0) {
            NSData *candidateData = [resultData copy];
            // Replacement takes priority. Some RAW/HEIF containers cannot
            // round-trip every private MakerApple field after their primary
            // image changes; returning the real photo in that case defeats the
            // virtual-camera contract. Keep the rewritten image and treat
            // metadata verification as diagnostics rather than a gate.
            VCPhotoDataPreservesAuthenticMetadata(candidateData,
                                                   sourceProperties,
                                                   CGImageGetWidth(replacementImage),
                                                   CGImageGetHeight(replacementImage));
            CFRelease(source);
            return candidateData;
        }
    }

    // Some source containers cannot be rewritten after replacing their primary image.
    // Preserve all portable camera/EXIF/GPS/TIFF properties in a standards-compliant
    // JPEG. A replacement is accepted only after its authentic device metadata
    // has been read back and verified against the real camera capture.
    NSMutableData *jpegData = [NSMutableData data];
    CGImageDestinationRef jpegDestination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)jpegData,
        CFSTR("public.jpeg"),
        1,
        NULL);
    BOOL jpegFinalized = NO;
    if (jpegDestination) {
        NSMutableDictionary *jpegProperties = [VCPhotoPropertiesForReplacement(source,
                                                                                 0,
                                                                                 replacementImage)
            mutableCopy];
        CGFloat clampedQuality = MIN(MAX(jpegQuality, 0.0), 1.0);
        jpegProperties[(id)kCGImageDestinationLossyCompressionQuality] = @(clampedQuality);
        CGImageDestinationAddImage(jpegDestination,
                                   replacementImage,
                                   (__bridge CFDictionaryRef)jpegProperties);
        jpegFinalized = CGImageDestinationFinalize(jpegDestination);
        CFRelease(jpegDestination);
    }
    CFRelease(source);
    NSData *verifiedJPEGData = jpegFinalized ? [jpegData copy] : nil;
    if (verifiedJPEGData.length > 0) {
        BOOL metadataVerified = VCPhotoDataPreservesAuthenticMetadata(
            verifiedJPEGData,
            sourceProperties,
            CGImageGetWidth(replacementImage),
            CGImageGetHeight(replacementImage));
        dispatch_once(&VCPhotoJPEGFallbackLogToken, ^{
            NSLog(@"[VirtualCamPro] Original photo container could not be rewritten; "
                   @"used virtual JPEG fallback (metadata %@)",
                  metadataVerified ? @"verified" : @"partially preserved");
        });
        return verifiedJPEGData;
    }
    return nil;
}


%hook AVCapturePhoto

- (AVDepthData *)depthData {
    if (VCPhotoUsesReplacement(self)) return nil;
    return %orig;
}

- (AVPortraitEffectsMatte *)portraitEffectsMatte {
    if (VCPhotoUsesReplacement(self)) return nil;
    return %orig;
}

- (AVSemanticSegmentationMatte *)semanticSegmentationMatteForType:
    (AVSemanticSegmentationMatteType)semanticSegmentationMatteType {
    if (VCPhotoUsesReplacement(self)) return nil;
    return %orig(semanticSegmentationMatteType);
}

- (CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef original = %orig;
    CVPixelBufferRef replacement = VCPhotoReplacementPixelBuffer(self,
                                                                  original,
                                                                  &VCPhotoPixelBufferAssociationKey);
    return replacement ?: original;
}

- (CVPixelBufferRef)previewPixelBuffer {
    CVPixelBufferRef original = %orig;
    CVPixelBufferRef replacement = VCPhotoReplacementPixelBuffer(self,
                                                                  original,
                                                                  &VCPhotoPreviewPixelBufferAssociationKey);
    return replacement ?: original;
}

- (CGImageRef)CGImageRepresentation {
    if (!VCPhotoHasCompatibilityReplacement(self)) return %orig;
    CVPixelBufferRef pixelBuffer = self.pixelBuffer;
    if (!pixelBuffer) return %orig;

    CGImageRef cgImage = VCCreatePhotoCGImage(pixelBuffer);
    if (!cgImage) return %orig;
    return cgImage;
}

- (CGImageRef)previewCGImageRepresentation {
    if (!VCPhotoHasCompatibilityReplacement(self)) return %orig;
    CVPixelBufferRef pixelBuffer = self.previewPixelBuffer;
    if (!pixelBuffer) return %orig;

    CGImageRef cgImage = VCCreatePhotoCGImage(pixelBuffer);
    if (!cgImage) return %orig;
    return cgImage;
}

- (NSData *)fileDataRepresentation {
    @synchronized (self) {
        NSData *cachedData = objc_getAssociatedObject(self, &VCPhotoFileDataAssociationKey);
        if (cachedData) return cachedData;

        if (!VCPhotoUsesReplacement(self)) return %orig;

        NSData *originalData = %orig;
        CVPixelBufferRef pixelBuffer = self.pixelBuffer;
        if (!pixelBuffer) {
            if (originalData) {
                objc_setAssociatedObject(self,
                                         &VCPhotoFileDataAssociationKey,
                                         originalData,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return originalData;
        }

        CGImageRef cgImage = VCCreatePhotoCGImage(pixelBuffer);
        if (!cgImage) {
            if (originalData) {
                objc_setAssociatedObject(self,
                                         &VCPhotoFileDataAssociationKey,
                                         originalData,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return originalData;
        }
        VCPhotoSourceSnapshot *snapshot =
            objc_getAssociatedObject(self, &VCPhotoSourceSnapshotAssociationKey);
        CGFloat jpegQuality = snapshot ? snapshot.jpegQuality
                                       : [VCStreamCoordinator sharedCoordinator].jpegQuality;
        NSData *photoData = VCPhotoDataByReplacingPrimaryImage(originalData,
                                                                cgImage,
                                                                jpegQuality);
        VCReportApplicationVideoRuntimeEvent(
            photoData
                ? VCApplicationVideoRuntimePhotoReplacementSucceeded
                : VCApplicationVideoRuntimePhotoReplacementFailed,
            0);
        if (!photoData) {
            dispatch_once(&VCPhotoMetadataFailureLogToken, ^{
                NSLog(@"[VirtualCamPro] Replacement photo metadata could not be verified; "
                       @"preserving the authentic original camera file");
            });
        }
        CGImageRelease(cgImage);
        NSData *resultData = photoData ?: originalData;
        if (resultData) {
            objc_setAssociatedObject(self,
                                     &VCPhotoFileDataAssociationKey,
                                     resultData,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return resultData;
    }
    return nil;
}

%end


%ctor {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        NSString *processName = NSProcessInfo.processInfo.processName;
        if ([processName isEqualToString:@"mediaserverd"] ||
            [bundleIdentifier isEqualToString:@"com.murkaska.virtualcampro.prefs"]) {
            return;
        }
        if ([processName isEqualToString:@"SpringBoard"] ||
            [bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            // VCMediaServer owns the only SpringBoard producer. This binary can
            // still be selected by a class-based Substrate filter, but must not
            // start a second decoder or install application hooks here.
            return;
        }
        VCPreferences *preferences = VCPreferences.sharedPreferences;
        [preferences reload];
        if (![preferences isCurrentProcessSelected]) {
            NSLog(@"[VirtualCamPro] Skipping unselected application %@ (%@)",
                  bundleIdentifier ?: @"<no bundle>",
                  processName ?: @"<no process>");
            return;
        }
        // Start the network decoder lazily when an application actually creates
        // an AVCapture preview or installs a video-output delegate.  The class-
        // based Substrate filter also reaches UIKit daemons that never open a
        // camera; eagerly starting HLS there exhausts AVFoundation outputs and
        // can destabilize mediaserverd.
        %init;
    }
}
