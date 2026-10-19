#import "AVAssetStreamAdapter.h"
#import "VCJPEGParser.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <math.h>
#import <os/lock.h>

#if TARGET_OS_IPHONE
// These symbols are exported by iOS VideoToolbox, but Apple's public SDK
// headers place their declarations inside a !TARGET_OS_IPHONE block.
extern const CFStringRef
    kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder;
extern const CFStringRef
    kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder;
#endif

static NSString * const VCStreamErrorDomain = @"com.murkaska.virtualcampro.stream";
static void *VCPlayerItemStatusContext = &VCPlayerItemStatusContext;
static const NSUInteger VCMaximumJPEGFrameBytes = 24 * 1024 * 1024;
static const NSUInteger VCMaximumMJPEGBufferBytes = 32 * 1024 * 1024;
static const NSUInteger VCMJPEGBufferCompactionThresholdBytes = 1024 * 1024;
// Three buffers are retained by the cross-process publication ring. Keep three
// additional allocations for the decoder/current fan-out so a temporarily slow
// photo or preview consumer does not force avoidable network-frame loss.
static const NSUInteger VCMaximumOutstandingMJPEGBuffers = 6;
static const NSInteger VCHLSInitialPollingFPS = 120;
static const NSInteger VCHLSMaximumPollingFPS = 240;
static const CFTimeInterval VCMJPEGStatisticsInterval = 5.0;

typedef struct {
    CVPixelBufferRef pixelBuffer;
    OSStatus status;
    VTDecodeInfoFlags infoFlags;
} VCMJPEGDecodeContext;

static void VCMJPEGDecompressionOutputCallback(
    __unused void *decompressionOutputRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    __unused CMTime presentationTimeStamp,
    __unused CMTime presentationDuration) {
    VCMJPEGDecodeContext *context = (VCMJPEGDecodeContext *)sourceFrameRefCon;
    if (!context) return;
    context->status = status;
    context->infoFlags = infoFlags;
    if (status == noErr && imageBuffer && !(infoFlags & kVTDecodeInfo_FrameDropped)) {
        context->pixelBuffer = CVPixelBufferRetain((CVPixelBufferRef)imageBuffer);
    }
}

static CGColorSpaceRef VCSharedRGBColorSpace(void) {
    static CGColorSpaceRef colorSpace;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return colorSpace;
}

@interface AVAssetStreamAdapter () {
    CVPixelBufferPoolRef _mjpegPixelBufferPool;
    size_t _mjpegPoolWidth;
    size_t _mjpegPoolHeight;
    CFAbsoluteTime _lastMJPEGErrorReportTime;
    VCJPEGParserState _mjpegParserState;
    NSUInteger _mjpegBufferOffset;
    os_unfair_lock _mjpegReceiveLock;
    NSData *_pendingMJPEGData;
    size_t _pendingMJPEGWidth;
    size_t _pendingMJPEGHeight;
    NSUInteger _pendingMJPEGConnectionGeneration;
    NSUInteger _mjpegConnectionGeneration;
    BOOL _mjpegDecodeScheduled;
    VTDecompressionSessionRef _mjpegDecompressionSession;
    CMVideoFormatDescriptionRef _mjpegVideoFormatDescription;
    size_t _mjpegDecoderWidth;
    size_t _mjpegDecoderHeight;
    size_t _mjpegVTDisabledWidth;
    size_t _mjpegVTDisabledHeight;
    CFAbsoluteTime _mjpegVTDisabledUntil;
    NSUInteger _mjpegVTConsecutiveFailures;
    BOOL _mjpegVTUsesHardware;
    uint64_t _mjpegParsedFrameCount;
    uint64_t _mjpegSupersededFrameCount;
    uint64_t _mjpegDecodedFrameCount;
    uint64_t _mjpegVTDecodedFrameCount;
    uint64_t _mjpegFallbackDecodedFrameCount;
    uint64_t _mjpegDecodeFailureCount;
    CFTimeInterval _mjpegTotalDecodeSeconds;
    CFAbsoluteTime _mjpegLastStatisticsTime;
    NSInteger _hlsPollingFPS;
}
@property (nonatomic, strong, readwrite) NSURL *streamURL;
@property (nonatomic, assign, readwrite) VCStreamProtocol streamProtocol;
@property (atomic, assign, readwrite, getter=isRunning) BOOL running;
@property (atomic, assign, readwrite, getter=isConnecting) BOOL connecting;
@property (atomic, assign, readwrite) NSUInteger frameCount;
@property (atomic, assign, readwrite) CFAbsoluteTime lastFrameTime;

@property (atomic, strong) NSURLSession *session;
@property (atomic, strong) NSURLSessionDataTask *task;
@property (atomic, strong) NSOperationQueue *delegateQueue;
@property (atomic, strong) NSMutableData *imageData;

@property (atomic, strong) AVPlayer *hlsPlayer;
@property (atomic, strong) AVPlayerItem *hlsPlayerItem;
@property (atomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) dispatch_source_t frameTimer;
@property (nonatomic, strong) dispatch_source_t healthTimer;
@property (nonatomic, strong) dispatch_queue_t hlsFrameQueue;
@property (nonatomic, strong) dispatch_queue_t mjpegDecodeQueue;
@property (nonatomic, assign) BOOL observingPlayerItem;
@property (nonatomic, assign) BOOL hlsLiveEdgeSeekInProgress;

@property (atomic, assign) NSUInteger reconnectAttempt;
@property (atomic, assign) NSUInteger lifecycleGeneration;
@property (atomic, assign) BOOL reconnectScheduled;
@property (atomic, assign) CFAbsoluteTime attemptStartTime;

- (CVPixelBufferPoolRef)mjpegPixelBufferPoolForWidth:(size_t)width
                                              height:(size_t)height;
- (CVPixelBufferRef)copyPixelBufferFromJPEGData:(NSData *)jpegData
                                          width:(size_t)width
                                         height:(size_t)height
                         usedVideoToolbox:(BOOL *)usedVideoToolbox CF_RETURNS_RETAINED;
- (CVPixelBufferRef)copyPixelBufferFromJPEGDataUsingVideoToolbox:(NSData *)jpegData
                                                           width:(size_t)width
                                                          height:(size_t)height CF_RETURNS_RETAINED;
- (CVPixelBufferRef)copyPixelBufferFromJPEGDataUsingImageIO:(NSData *)jpegData
                                                      width:(size_t)width
                                                     height:(size_t)height CF_RETURNS_RETAINED;
- (BOOL)prepareMJPEGDecompressionSessionForWidth:(size_t)width height:(size_t)height;
- (void)recordMJPEGVideoToolboxFailureForWidth:(size_t)width height:(size_t)height;
- (void)releaseMJPEGPixelBufferPool;
- (void)releaseMJPEGDecompressionSession;
- (void)resetMJPEGReceiveBufferLocked;
- (void)compactMJPEGReceiveBufferLockedIfNeeded:(BOOL)force;
- (void)reportMalformedMJPEGStream:(NSString *)description;
- (void)decodePendingMJPEGFrames;
- (void)catchUpToHLSLiveEdgeIfNeeded;
- (void)configureHLSFrameTimerForPlayerItem:(AVPlayerItem *)item;
@end

@implementation AVAssetStreamAdapter

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _streamURL = url;
        _mjpegReceiveLock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        dispatch_queue_attr_t hlsQueueAttributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                     QOS_CLASS_USER_INTERACTIVE,
                                                     0);
        _hlsFrameQueue = dispatch_queue_create("com.murkaska.virtualcampro.hls-frames",
                                               hlsQueueAttributes);
        _mjpegDecodeQueue = dispatch_queue_create(
            "com.murkaska.virtualcampro.mjpeg-decode", hlsQueueAttributes);
        NSString *absoluteString = url.absoluteString.lowercaseString;
        _streamProtocol = [absoluteString containsString:@".m3u8"] ? VCStreamProtocolHLS : VCStreamProtocolMJPEG;
    }
    return self;
}

- (void)startStreaming {
    @synchronized (self) {
        if (self.running) return;
        self.running = YES;
        self.connecting = YES;
        self.reconnectAttempt = 0;
        self.reconnectScheduled = NO;
        self.frameCount = 0;
        self.lastFrameTime = 0;
        self.attemptStartTime = CFAbsoluteTimeGetCurrent();
        self.lifecycleGeneration++;
    }

    [self startHealthMonitor];

    if (self.streamProtocol == VCStreamProtocolHLS) {
        [self startHLSStream];
    } else {
        [self startMJPEGStream];
    }
}

- (void)stopStreaming {
    @synchronized (self) {
        if (!self.running && !self.connecting) return;
        self.running = NO;
        self.connecting = NO;
        self.reconnectScheduled = NO;
        self.lifecycleGeneration++;
    }

    [self stopMJPEGStream];
    [self stopHLSStream];
    [self stopHealthMonitor];
}

- (void)handleMemoryPressure {
    NSOperationQueue *queue = self.delegateQueue;
    if (queue) {
        __weak AVAssetStreamAdapter *weakSelf = self;
        [queue addOperationWithBlock:^{
            AVAssetStreamAdapter *strongSelf = weakSelf;
            if (!strongSelf) return;
            os_unfair_lock_lock(&strongSelf->_mjpegReceiveLock);
            [strongSelf resetMJPEGReceiveBufferLocked];
            os_unfair_lock_unlock(&strongSelf->_mjpegReceiveLock);
        }];
    } else {
        os_unfair_lock_lock(&_mjpegReceiveLock);
        [self resetMJPEGReceiveBufferLocked];
        os_unfair_lock_unlock(&_mjpegReceiveLock);
    }
    // Pool creation and JPEG rendering live exclusively on this queue. Keeping
    // pressure cleanup there prevents releasing a pool while ImageIO is still
    // allocating/rendering its current frame.
    dispatch_async(self.mjpegDecodeQueue, ^{
        [self releaseMJPEGDecompressionSession];
        [self releaseMJPEGPixelBufferPool];
    });
}

#pragma mark - Shared state

- (void)deliverPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;

    AVAssetPixelBufferCallback callback = nil;
    @synchronized (self) {
        if (!self.running) return;
        self.frameCount++;
        self.lastFrameTime = CFAbsoluteTimeGetCurrent();
        self.connecting = NO;
        self.reconnectAttempt = 0;
        if (self.reconnectScheduled) {
            self.reconnectScheduled = NO;
            self.lifecycleGeneration++;
        }
        callback = [self.pixelBufferCallback copy];
    }
    if (callback) callback(pixelBuffer);
}

- (void)reportError:(NSError *)error {
    AVAssetErrorCallback callback = [self.errorCallback copy];
    if (!error || !callback) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        callback(error);
    });
}

- (void)scheduleReconnectAfterError:(NSError *)error {
    NSUInteger attempt;
    NSUInteger generation;
    @synchronized (self) {
        if (!self.running || self.reconnectScheduled) return;
        self.reconnectScheduled = YES;
        self.connecting = YES;
        attempt = MIN(self.reconnectAttempt, 5);
        self.reconnectAttempt++;
        generation = self.lifecycleGeneration;
    }
    [self reportError:error];

    NSTimeInterval delay = MIN(30.0, pow(2.0, attempt));

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized (self) {
            if (!self.running || generation != self.lifecycleGeneration) return;
            self.reconnectScheduled = NO;
        }

        if (self.streamProtocol == VCStreamProtocolHLS) {
            [self stopHLSStreamImmediately];
            [self startHLSStreamImmediately];
        } else {
            [self stopMJPEGStream];
            [self startMJPEGStream];
        }
    });
}

- (void)startHealthMonitor {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.running || self.healthTimer) return;
        self.healthTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                  0,
                                                  0,
                                                  dispatch_get_main_queue());
        dispatch_source_set_timer(self.healthTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC,
                                  NSEC_PER_SEC / 5);
        __weak AVAssetStreamAdapter *weakSelf = self;
        dispatch_source_set_event_handler(self.healthTimer, ^{
            [weakSelf verifyStreamHealth];
        });
        dispatch_resume(self.healthTimer);
    });
}

- (void)stopHealthMonitor {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.healthTimer) return;
        dispatch_source_cancel(self.healthTimer);
        self.healthTimer = nil;
    });
}

- (void)verifyStreamHealth {
    if (self.streamProtocol == VCStreamProtocolHLS) {
        [self catchUpToHLSLiveEdgeIfNeeded];
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime referenceTime;
    NSTimeInterval timeout;
    BOOL receivedFrameInThisAttempt;
    @synchronized (self) {
        if (!self.running || self.reconnectScheduled) return;
        receivedFrameInThisAttempt = self.lastFrameTime > 0;
        if (receivedFrameInThisAttempt) {
            referenceTime = self.lastFrameTime;
            timeout = 8.0;
        } else {
            referenceTime = self.attemptStartTime;
            timeout = 15.0;
        }
    }
    if (referenceTime <= 0 || now - referenceTime <= timeout) return;

    NSString *description = receivedFrameInThisAttempt
        ? @"Stream stopped producing frames"
        : @"Stream did not produce its first frame";
    NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                         code:1004
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
    [self scheduleReconnectAfterError:error];
}

- (void)catchUpToHLSLiveEdgeIfNeeded {
    AVPlayerItem *item = self.hlsPlayerItem;
    AVPlayer *player = self.hlsPlayer;
    if (!self.running || !item || !player || self.hlsLiveEdgeSeekInProgress ||
        item.status != AVPlayerItemStatusReadyToPlay || item.seekableTimeRanges.count == 0) {
        return;
    }
    CMTimeRange liveRange = item.seekableTimeRanges.lastObject.CMTimeRangeValue;
    CMTime liveEdge = CMTimeRangeGetEnd(liveRange);
    CMTime current = player.currentTime;
    Float64 secondsBehind = CMTimeGetSeconds(CMTimeSubtract(liveEdge, current));
    if (!isfinite(secondsBehind) || secondsBehind <= 1.0) return;
    CMTime target = CMTimeSubtract(liveEdge, CMTimeMakeWithSeconds(0.10, 600));
    if (CMTIME_COMPARE_INLINE(target, <, liveRange.start)) target = liveRange.start;
    self.hlsLiveEdgeSeekInProgress = YES;
    __weak AVAssetStreamAdapter *weakSelf = self;
    [player seekToTime:target
       toleranceBefore:kCMTimeZero
        toleranceAfter:kCMTimeZero
     completionHandler:^(__unused BOOL finished) {
        AVAssetStreamAdapter *strongSelf = weakSelf;
        strongSelf.hlsLiveEdgeSeekInProgress = NO;
        if (strongSelf.running) [strongSelf.hlsPlayer play];
    }];
}

#pragma mark - HLS

- (void)startHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.running) return;
        [self startHLSStreamImmediately];
    });
}

- (void)startHLSStreamImmediately {
    if (!self.running || self.hlsPlayerItem) return;
    @synchronized (self) {
        self.attemptStartTime = CFAbsoluteTimeGetCurrent();
        self.lastFrameTime = 0;
    }

    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{
            (id)kIOSurfaceIsGlobal: @YES,
        },
    };

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.streamURL];
    // This is a live camera feed, not on-demand playback.  AVPlayer still owns
    // protocol adaptation, but it must not intentionally build a second phone-
    // side quality/rate buffer on top of the sender's live window.
    item.preferredForwardBufferDuration = 1.5;
    AVPlayerItemVideoOutput *output = [[AVPlayerItemVideoOutput alloc]
                                       initWithPixelBufferAttributes:pixelBufferAttributes];
    if (!output) {
        NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                             code:1006
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        @"AVFoundation could not create an HLS video output"}];
        [self scheduleReconnectAfterError:error];
        return;
    }
    output.suppressesPlayerRendering = YES;
    @try {
        [item addOutput:output];
    } @catch (NSException *exception) {
        NSString *description = [NSString stringWithFormat:
            @"AVFoundation rejected the HLS video output: %@",
            exception.reason ?: exception.name];
        NSLog(@"[VirtualCamPro] %@", description);
        NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                             code:1007
                                         userInfo:@{NSLocalizedDescriptionKey: description}];
        [self scheduleReconnectAfterError:error];
        return;
    }

    self.hlsPlayerItem = item;
    self.videoOutput = output;
    self.hlsPlayer = [AVPlayer playerWithPlayerItem:item];
    self.hlsPlayer.automaticallyWaitsToMinimizeStalling = NO;
    self.hlsPlayer.muted = YES;

    [item addObserver:self
           forKeyPath:@"status"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:VCPlayerItemStatusContext];
    self.observingPlayerItem = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(playerItemDidReachEnd:)
                   name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    [center addObserver:self selector:@selector(playerItemPlaybackStalled:)
                   name:AVPlayerItemPlaybackStalledNotification object:item];

    // Poll faster than common source rates. hasNewPixelBufferForItemTime: is the
    // rate gate, so this observes the sender cadence without inventing or dropping
    // frames according to a phone preference.
    _hlsPollingFPS = VCHLSInitialPollingFPS;
    uint64_t interval = NSEC_PER_SEC / (uint64_t)_hlsPollingFPS;
    self.frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                              0,
                                              0,
                                              self.hlsFrameQueue);
    dispatch_source_set_timer(self.frameTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              interval,
                              interval / 10);
    __weak AVAssetStreamAdapter *weakSelf = self;
    dispatch_source_set_event_handler(self.frameTimer, ^{
        [weakSelf pullHLSFrame];
    });
    dispatch_resume(self.frameTimer);
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != VCPlayerItemStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    AVPlayerItem *item = object;
    if (item != self.hlsPlayerItem || !self.running) return;

    if (item.status == AVPlayerItemStatusReadyToPlay) {
        NSLog(@"[VirtualCamPro] HLS player ready in %@",
              NSProcessInfo.processInfo.processName);
        @synchronized (self) {
            self.connecting = NO;
            self.reconnectAttempt = 0;
        }
        [self configureHLSFrameTimerForPlayerItem:item];
        [self.hlsPlayer play];
    } else if (item.status == AVPlayerItemStatusFailed) {
        NSError *error = item.error ?: [NSError errorWithDomain:VCStreamErrorDomain
                                                               code:1001
                                                           userInfo:@{NSLocalizedDescriptionKey: @"HLS stream failed to load"}];
        NSLog(@"[VirtualCamPro] HLS player failed in %@: %@",
              NSProcessInfo.processInfo.processName,
              error.localizedDescription);
        [self scheduleReconnectAfterError:error];
    }
}

- (void)pullHLSFrame {
    AVPlayerItem *playerItem = self.hlsPlayerItem;
    AVPlayerItemVideoOutput *videoOutput = self.videoOutput;
    AVPlayer *player = self.hlsPlayer;
    if (!self.running || !playerItem || !videoOutput ||
        playerItem.status != AVPlayerItemStatusReadyToPlay) return;

    CMTime itemTime = [videoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_VALID(itemTime)) itemTime = player.currentTime;
    if (![videoOutput hasNewPixelBufferForItemTime:itemTime]) return;

    CVPixelBufferRef pixelBuffer = [videoOutput copyPixelBufferForItemTime:itemTime
                                                        itemTimeForDisplay:nil];
    if (!pixelBuffer) return;
    [self deliverPixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    if (!self.running) return;
    [self.hlsPlayer seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
        if (finished && self.running) [self.hlsPlayer play];
    }];
}

- (void)playerItemPlaybackStalled:(NSNotification *)notification {
    if (!self.running || notification.object != self.hlsPlayerItem) return;
    // AVPlayer can emit this notification while a live playlist is merely
    // waiting for its next one-second segment.  Rebuilding the player here
    // turns that harmless startup underrun into a permanent reconnect loop.
    // Resume toward the live edge and let the health monitor reconnect only
    // if frames are actually absent for its full timeout window.
    NSLog(@"[VirtualCamPro] HLS playback briefly stalled in %@; waiting for the live playlist",
          NSProcessInfo.processInfo.processName);
    [self catchUpToHLSLiveEdgeIfNeeded];
    [self.hlsPlayer play];
}

- (void)stopHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopHLSStreamImmediately];
    });
}

- (void)stopHLSStreamImmediately {
    AVPlayerItem *item = self.hlsPlayerItem;
    AVPlayerItemVideoOutput *output = self.videoOutput;
    AVAsset *loadingAsset = item.asset;
    if (self.observingPlayerItem && item) {
        [item removeObserver:self forKeyPath:@"status" context:VCPlayerItemStatusContext];
        self.observingPlayerItem = NO;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:self.hlsPlayerItem];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemPlaybackStalledNotification
                                                  object:self.hlsPlayerItem];
    if (self.frameTimer) {
        dispatch_source_cancel(self.frameTimer);
        self.frameTimer = nil;
    }
    _hlsPollingFPS = 0;
    [self.hlsPlayer pause];
    self.hlsLiveEdgeSeekInProgress = NO;
    if (item && output && [item.outputs containsObject:output]) {
        @try {
            [item removeOutput:output];
        } @catch (__unused NSException *exception) {
            // The item may already be tearing down after a failed load.
        }
    }
    self.hlsPlayer = nil;
    self.hlsPlayerItem = nil;
    self.videoOutput = nil;
    [loadingAsset cancelLoading];
}

#pragma mark - MJPEG

- (void)startMJPEGStream {
    if (!self.running || self.task) return;
    @synchronized (self) {
        self.attemptStartTime = CFAbsoluteTimeGetCurrent();
        self.lastFrameTime = 0;
    }
    os_unfair_lock_lock(&_mjpegReceiveLock);
    _lastMJPEGErrorReportTime = 0;
    _mjpegConnectionGeneration++;
    _pendingMJPEGData = nil;
    _pendingMJPEGWidth = 0;
    _pendingMJPEGHeight = 0;
    _mjpegParsedFrameCount = 0;
    _mjpegSupersededFrameCount = 0;
    _mjpegDecodedFrameCount = 0;
    _mjpegVTDecodedFrameCount = 0;
    _mjpegFallbackDecodedFrameCount = 0;
    _mjpegDecodeFailureCount = 0;
    _mjpegTotalDecodeSeconds = 0;
    _mjpegLastStatisticsTime = CFAbsoluteTimeGetCurrent();
    _mjpegVTDisabledWidth = 0;
    _mjpegVTDisabledHeight = 0;
    _mjpegVTDisabledUntil = 0;
    self.imageData = [NSMutableData data];
    [self resetMJPEGReceiveBufferLocked];
    os_unfair_lock_unlock(&_mjpegReceiveLock);

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 20.0;
    // A multipart response is intentionally long-lived. Reconnect once a day so a
    // half-open connection cannot survive forever without exercising recovery.
    configuration.timeoutIntervalForResource = 24.0 * 60.0 * 60.0;
    configuration.HTTPMaximumConnectionsPerHost = 1;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    self.delegateQueue = [[NSOperationQueue alloc] init];
    self.delegateQueue.maxConcurrentOperationCount = 1;
    self.delegateQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    self.session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:self.delegateQueue];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.streamURL];
    [request setValue:@"multipart/x-mixed-replace,image/jpeg;q=0.9,*/*;q=0.1"
   forHTTPHeaderField:@"Accept"];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)stopMJPEGStream {
    NSURLSessionDataTask *task = self.task;
    NSURLSession *session = self.session;
    self.task = nil;
    self.session = nil;
    self.delegateQueue = nil;
    os_unfair_lock_lock(&_mjpegReceiveLock);
    _mjpegConnectionGeneration++;
    _pendingMJPEGData = nil;
    _pendingMJPEGWidth = 0;
    _pendingMJPEGHeight = 0;
    self.imageData = nil;
    [self resetMJPEGReceiveBufferLocked];
    os_unfair_lock_unlock(&_mjpegReceiveLock);
    [task cancel];
    [session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if (session != self.session || dataTask != self.task || !self.running) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
                                         ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    if (httpResponse && (statusCode < 200 || statusCode >= 300)) {
        NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                         code:statusCode
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"MJPEG server returned HTTP %ld", (long)statusCode]}];
        completionHandler(NSURLSessionResponseCancel);
        [self scheduleReconnectAfterError:error];
        return;
    }

    NSString *mimeType = response.MIMEType.lowercaseString;
    if ([mimeType isEqualToString:@"text/html"] ||
        [mimeType isEqualToString:@"application/json"] ||
        [mimeType containsString:@"mpegurl"]) {
        NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                         code:1005
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                        @"Unexpected MJPEG content type: %@",
                                                        mimeType]}];
        completionHandler(NSURLSessionResponseCancel);
        [self scheduleReconnectAfterError:error];
        return;
    }

    @synchronized (self) {
        self.connecting = NO;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (BOOL)prepareMJPEGDecompressionSessionForWidth:(size_t)width height:(size_t)height {
    if (_mjpegDecompressionSession && _mjpegVideoFormatDescription &&
        _mjpegDecoderWidth == width && _mjpegDecoderHeight == height) {
        return YES;
    }
    [self releaseMJPEGDecompressionSession];
    if (_mjpegVTDisabledWidth == width && _mjpegVTDisabledHeight == height) {
        if (CFAbsoluteTimeGetCurrent() < _mjpegVTDisabledUntil) return NO;
        _mjpegVTDisabledWidth = 0;
        _mjpegVTDisabledHeight = 0;
        _mjpegVTDisabledUntil = 0;
    }
    if (width == 0 || height == 0 || width > 4096 || height > 4096 ||
        width * height > 16000000) {
        return NO;
    }

    OSStatus formatStatus = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                            kCMVideoCodecType_JPEG,
                                                            (int32_t)width,
                                                            (int32_t)height,
                                                            NULL,
                                                            &_mjpegVideoFormatDescription);
    if (formatStatus != noErr || !_mjpegVideoFormatDescription) {
        _mjpegVTDisabledWidth = width;
        _mjpegVTDisabledHeight = height;
        _mjpegVTDisabledUntil = CFAbsoluteTimeGetCurrent() + 30.0;
        return NO;
    }

    NSDictionary *decoderSpecification = @{
        (__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:
            @YES,
    };
    NSDictionary *pixelBufferAttributes = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{
            (id)kIOSurfaceIsGlobal: @YES,
        },
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    VTDecompressionOutputCallbackRecord callbackRecord = {
        .decompressionOutputCallback = VCMJPEGDecompressionOutputCallback,
        .decompressionOutputRefCon = NULL,
    };
    OSStatus sessionStatus = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        _mjpegVideoFormatDescription,
        (__bridge CFDictionaryRef)decoderSpecification,
        (__bridge CFDictionaryRef)pixelBufferAttributes,
        &callbackRecord,
        &_mjpegDecompressionSession);
    if (sessionStatus != noErr || !_mjpegDecompressionSession) {
        [self releaseMJPEGDecompressionSession];
        _mjpegVTDisabledWidth = width;
        _mjpegVTDisabledHeight = height;
        _mjpegVTDisabledUntil = CFAbsoluteTimeGetCurrent() + 30.0;
        return NO;
    }
    VTSessionSetProperty(_mjpegDecompressionSession,
                         kVTDecompressionPropertyKey_RealTime,
                         kCFBooleanTrue);
    CFTypeRef hardwareProperty = NULL;
    OSStatus hardwareStatus = VTSessionCopyProperty(
        _mjpegDecompressionSession,
        kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
        kCFAllocatorDefault,
        &hardwareProperty);
    _mjpegVTUsesHardware = hardwareStatus == noErr && hardwareProperty &&
        CFGetTypeID(hardwareProperty) == CFBooleanGetTypeID() &&
        CFBooleanGetValue((CFBooleanRef)hardwareProperty);
    if (hardwareProperty) CFRelease(hardwareProperty);
    _mjpegDecoderWidth = width;
    _mjpegDecoderHeight = height;
    _mjpegVTDisabledWidth = 0;
    _mjpegVTDisabledHeight = 0;
    _mjpegVTDisabledUntil = 0;
    _mjpegVTConsecutiveFailures = 0;
    NSLog(@"[VirtualCamPro] MJPEG VideoToolbox decoder ready: %zux%zu, hardware=%@",
          width, height, _mjpegVTUsesHardware ? @"yes" : @"no");
    return YES;
}

- (void)configureHLSFrameTimerForPlayerItem:(AVPlayerItem *)item {
    if (!item || !self.frameTimer) return;
    AVAsset *asset = item.asset;
    __weak AVAssetStreamAdapter *weakSelf = self;
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack *> *videoTracks,
                                     NSError *trackError) {
        AVAssetStreamAdapter *strongSelf = weakSelf;
        if (!strongSelf || trackError || videoTracks.count == 0) return;
        dispatch_group_t propertyGroup = dispatch_group_create();
        for (AVAssetTrack *videoTrack in videoTracks) {
            dispatch_group_enter(propertyGroup);
            [videoTrack loadValuesAsynchronouslyForKeys:@[@"nominalFrameRate"]
                                      completionHandler:^{
                dispatch_group_leave(propertyGroup);
            }];
        }
        dispatch_group_notify(propertyGroup, dispatch_get_main_queue(), ^{
            AVAssetStreamAdapter *liveSelf = weakSelf;
            if (!liveSelf || !liveSelf.running || item != liveSelf.hlsPlayerItem ||
                !liveSelf.frameTimer) return;
            float nominalFPS = 0;
            for (AVAssetTrack *videoTrack in videoTracks) {
                NSError *propertyError = nil;
                AVKeyValueStatus status = [videoTrack
                    statusOfValueForKey:@"nominalFrameRate"
                                  error:&propertyError];
                if (status != AVKeyValueStatusLoaded) continue;
                float trackFPS = videoTrack.nominalFrameRate;
                if (isfinite(trackFPS) && trackFPS > 0) {
                    nominalFPS = MAX(nominalFPS, trackFPS);
                }
            }
            NSInteger pollingFPS = nominalFPS > 0
                ? (NSInteger)ceil(nominalFPS * 2.0) : VCHLSInitialPollingFPS;
            pollingFPS = MAX(30, MIN(VCHLSMaximumPollingFPS, pollingFPS));
            if (liveSelf->_hlsPollingFPS == pollingFPS) return;
            liveSelf->_hlsPollingFPS = pollingFPS;
            uint64_t interval = NSEC_PER_SEC / (uint64_t)pollingFPS;
            dispatch_source_set_timer(liveSelf.frameTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 0),
                                      interval,
                                      MAX((uint64_t)1, interval / 10));
            NSLog(@"[VirtualCamPro] HLS frame polling adapted to %ld Hz (nominal %.2f FPS)",
                  (long)pollingFPS,
                  nominalFPS);
        });
    }];
}

- (void)releaseMJPEGDecompressionSession {
    if (_mjpegDecompressionSession) {
        VTDecompressionSessionInvalidate(_mjpegDecompressionSession);
        CFRelease(_mjpegDecompressionSession);
        _mjpegDecompressionSession = NULL;
    }
    if (_mjpegVideoFormatDescription) {
        CFRelease(_mjpegVideoFormatDescription);
        _mjpegVideoFormatDescription = NULL;
    }
    _mjpegDecoderWidth = 0;
    _mjpegDecoderHeight = 0;
    _mjpegVTConsecutiveFailures = 0;
    _mjpegVTUsesHardware = NO;
}

- (void)recordMJPEGVideoToolboxFailureForWidth:(size_t)width height:(size_t)height {
    _mjpegVTConsecutiveFailures++;
    if (_mjpegVTConsecutiveFailures < 3) return;
    [self releaseMJPEGDecompressionSession];
    _mjpegVTDisabledWidth = width;
    _mjpegVTDisabledHeight = height;
    // Hardware sessions can fail transiently during pressure or decoder
    // reconfiguration. Use ImageIO briefly, then probe VideoToolbox again
    // instead of pinning this resolution to CPU decode for the process life.
    _mjpegVTDisabledUntil = CFAbsoluteTimeGetCurrent() + 30.0;
}

- (CVPixelBufferRef)copyPixelBufferFromJPEGDataUsingVideoToolbox:(NSData *)jpegData
                                                           width:(size_t)width
                                                          height:(size_t)height CF_RETURNS_RETAINED {
    if (![self prepareMJPEGDecompressionSessionForWidth:width height:height]) return NULL;

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus blockStatus = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        (void *)jpegData.bytes,
        jpegData.length,
        kCFAllocatorNull,
        NULL,
        0,
        jpegData.length,
        0,
        &blockBuffer);
    if (blockStatus != kCMBlockBufferNoErr || !blockBuffer) {
        [self recordMJPEGVideoToolboxFailureForWidth:width height:height];
        return NULL;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    size_t sampleSize = jpegData.length;
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    OSStatus sampleStatus = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                                       blockBuffer,
                                                       _mjpegVideoFormatDescription,
                                                       1,
                                                       1,
                                                       &timing,
                                                       1,
                                                       &sampleSize,
                                                       &sampleBuffer);
    CFRelease(blockBuffer);
    if (sampleStatus != noErr || !sampleBuffer) {
        [self recordMJPEGVideoToolboxFailureForWidth:width height:height];
        return NULL;
    }

    VCMJPEGDecodeContext context = {
        .pixelBuffer = NULL,
        .status = noErr,
        .infoFlags = 0,
    };
    VTDecodeInfoFlags decodeFlags = 0;
    OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_mjpegDecompressionSession,
                                                               sampleBuffer,
                                                               0,
                                                               &context,
                                                               &decodeFlags);
    CFRelease(sampleBuffer);
    BOOL succeeded = decodeStatus == noErr && context.status == noErr &&
        context.pixelBuffer && !(decodeFlags & kVTDecodeInfo_FrameDropped) &&
        !(context.infoFlags & kVTDecodeInfo_FrameDropped);
    if (succeeded) {
        _mjpegVTConsecutiveFailures = 0;
        return context.pixelBuffer;
    }
    if (context.pixelBuffer) CVPixelBufferRelease(context.pixelBuffer);
    [self recordMJPEGVideoToolboxFailureForWidth:width height:height];
    return NULL;
}

- (CVPixelBufferRef)copyPixelBufferFromJPEGDataUsingImageIO:(NSData *)jpegData
                                                      width:(size_t)declaredWidth
                                                     height:(size_t)declaredHeight CF_RETURNS_RETAINED {
    if (declaredWidth > 4096 || declaredHeight > 4096 ||
        (declaredWidth > 0 && declaredHeight > 0 &&
         declaredWidth * declaredHeight > 16000000)) {
        return NULL;
    }
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
    if (!imageSource) return NULL;
    if (declaredWidth == 0 || declaredHeight == 0) {
        NSDictionary *properties = CFBridgingRelease(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL));
        declaredWidth = [properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
        declaredHeight = [properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    }
    if (declaredWidth == 0 || declaredHeight == 0 || declaredWidth > 4096 ||
        declaredHeight > 4096 || declaredWidth * declaredHeight > 16000000) {
        CFRelease(imageSource);
        return NULL;
    }
    NSDictionary *decodeOptions = @{
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    // Decode the sender's pixels at the sender's dimensions. In particular, do
    // not apply EXIF orientation or a phone-side thumbnail quality cap.
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(
        imageSource, 0, (__bridge CFDictionaryRef)decodeOptions);
    CFRelease(imageSource);
    if (!cgImage) return NULL;

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0 || width > 4096 || height > 4096 || width * height > 16000000) {
        CGImageRelease(cgImage);
        return NULL;
    }
    if (width != declaredWidth || height != declaredHeight) {
        CGImageRelease(cgImage);
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferPoolRef pool = [self mjpegPixelBufferPoolForWidth:width height:height];
    static NSDictionary *allocationAttributes;
    static dispatch_once_t allocationAttributesToken;
    dispatch_once(&allocationAttributesToken, ^{
        allocationAttributes = @{
            (id)kCVPixelBufferPoolAllocationThresholdKey:
                @(VCMaximumOutstandingMJPEGBuffers),
        };
    });
    CVReturn result = pool ? CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                                kCFAllocatorDefault,
                                pool,
                                (__bridge CFDictionaryRef)allocationAttributes,
                                &pixelBuffer)
                           : kCVReturnInvalidArgument;
    if (result != kCVReturnSuccess || !pixelBuffer) {
        CGImageRelease(cgImage);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = VCSharedRGBColorSpace();
    CGContextRef context = CGBitmapContextCreate(baseAddress,
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

    if (!context) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        CGImageRelease(cgImage);
        return NULL;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    CGImageRelease(cgImage);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return pixelBuffer;
}

- (CVPixelBufferRef)copyPixelBufferFromJPEGData:(NSData *)jpegData
                                          width:(size_t)width
                                         height:(size_t)height
                         usedVideoToolbox:(BOOL *)usedVideoToolbox CF_RETURNS_RETAINED {
    if (usedVideoToolbox) *usedVideoToolbox = NO;
    if (!jpegData || jpegData.length == 0) return NULL;
    if (width > 0 && height > 0) {
        CVPixelBufferRef hardwareBuffer =
            [self copyPixelBufferFromJPEGDataUsingVideoToolbox:jpegData
                                                         width:width
                                                        height:height];
        if (hardwareBuffer) {
            if (usedVideoToolbox) *usedVideoToolbox = YES;
            return hardwareBuffer;
        }
    }
    return [self copyPixelBufferFromJPEGDataUsingImageIO:jpegData
                                                   width:width
                                                  height:height];
}

- (CVPixelBufferPoolRef)mjpegPixelBufferPoolForWidth:(size_t)width
                                              height:(size_t)height {
    if (_mjpegPixelBufferPool && _mjpegPoolWidth == width && _mjpegPoolHeight == height) {
        return _mjpegPixelBufferPool;
    }

    if (_mjpegPixelBufferPool) {
        CVPixelBufferPoolRelease(_mjpegPixelBufferPool);
        _mjpegPixelBufferPool = NULL;
    }
    _mjpegPoolWidth = 0;
    _mjpegPoolHeight = 0;

    NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
    };
    NSDictionary *bufferAttributes = @{
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{
            (id)kIOSurfaceIsGlobal: @YES,
        },
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                               (__bridge CFDictionaryRef)poolAttributes,
                                               (__bridge CFDictionaryRef)bufferAttributes,
                                               &_mjpegPixelBufferPool);
    if (result != kCVReturnSuccess || !_mjpegPixelBufferPool) return NULL;
    _mjpegPoolWidth = width;
    _mjpegPoolHeight = height;
    return _mjpegPixelBufferPool;
}

- (void)releaseMJPEGPixelBufferPool {
    if (_mjpegPixelBufferPool) {
        CVPixelBufferPoolFlush(_mjpegPixelBufferPool,
                               kCVPixelBufferPoolFlushExcessBuffers);
        CVPixelBufferPoolRelease(_mjpegPixelBufferPool);
        _mjpegPixelBufferPool = NULL;
    }
    _mjpegPoolWidth = 0;
    _mjpegPoolHeight = 0;
}

- (void)resetMJPEGReceiveBufferLocked {
    [self.imageData setLength:0];
    _mjpegBufferOffset = 0;
    VCJPEGParserReset(&_mjpegParserState);
}

- (void)compactMJPEGReceiveBufferLockedIfNeeded:(BOOL)force {
    NSMutableData *imageData = self.imageData;
    if (!imageData || _mjpegBufferOffset == 0) return;
    if (_mjpegBufferOffset >= imageData.length) {
        [imageData setLength:0];
        _mjpegBufferOffset = 0;
        return;
    }
    if (!force && _mjpegBufferOffset < VCMJPEGBufferCompactionThresholdBytes) return;
    [imageData replaceBytesInRange:NSMakeRange(0, _mjpegBufferOffset)
                         withBytes:NULL
                            length:0];
    _mjpegBufferOffset = 0;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (session != self.session || dataTask != self.task || !self.running || data.length == 0) return;
    os_unfair_lock_lock(&_mjpegReceiveLock);
    if (session != self.session || dataTask != self.task || !self.running) {
        os_unfair_lock_unlock(&_mjpegReceiveLock);
        return;
    }
    NSMutableData *imageData = self.imageData;
    if (!imageData) {
        os_unfair_lock_unlock(&_mjpegReceiveLock);
        return;
    }

    if (_mjpegBufferOffset > imageData.length) {
        [self resetMJPEGReceiveBufferLocked];
    } else if (_mjpegBufferOffset > 0 &&
               (imageData.length > VCMaximumMJPEGBufferBytes - MIN(data.length,
                                                                    VCMaximumMJPEGBufferBytes) ||
                _mjpegBufferOffset >= VCMJPEGBufferCompactionThresholdBytes)) {
        [self compactMJPEGReceiveBufferLockedIfNeeded:YES];
    }
    NSUInteger activeBufferLength = imageData.length - _mjpegBufferOffset;
    if (data.length > VCMaximumMJPEGBufferBytes ||
        activeBufferLength > VCMaximumMJPEGBufferBytes - data.length) {
        [self resetMJPEGReceiveBufferLocked];
        [self reportMalformedMJPEGStream:@"MJPEG receive buffer exceeded its safety limit"];
        if (data.length > VCMaximumMJPEGBufferBytes) {
            os_unfair_lock_unlock(&_mjpegReceiveLock);
            return;
        }
    }
    [imageData appendData:data];

    NSData *latestJPEGData = nil;
    size_t latestJPEGWidth = 0;
    size_t latestJPEGHeight = 0;

    static NSData *startMarker;
    static dispatch_once_t markerToken;
    dispatch_once(&markerToken, ^{
        static const unsigned char startBytes[] = {0xFF, 0xD8};
        startMarker = [NSData dataWithBytes:startBytes length:sizeof(startBytes)];
    });

    while (imageData.length - _mjpegBufferOffset >= 2) {
        NSRange fullRange = NSMakeRange(_mjpegBufferOffset,
                                       imageData.length - _mjpegBufferOffset);
        NSRange startRange = [imageData rangeOfData:startMarker options:0 range:fullRange];
        if (startRange.location == NSNotFound) {
            unsigned char trailingByte = ((const unsigned char *)imageData.bytes)[imageData.length - 1];
            [self resetMJPEGReceiveBufferLocked];
            if (trailingByte == 0xFF) [imageData appendBytes:&trailingByte length:1];
            break;
        }

        if (startRange.location > _mjpegBufferOffset) {
            _mjpegBufferOffset = startRange.location;
            VCJPEGParserReset(&_mjpegParserState);
        }

        NSUInteger availableImageBytes = imageData.length - _mjpegBufferOffset;
        const uint8_t *imageBytes = (const uint8_t *)imageData.bytes + _mjpegBufferOffset;
        size_t parsedImageLength = 0;
        VCJPEGParserResult parserResult = VCJPEGParserConsume(imageBytes,
                                                              availableImageBytes,
                                                              &_mjpegParserState,
                                                              &parsedImageLength);
        if (parserResult == VCJPEGParserResultInvalid) {
            _mjpegBufferOffset += startMarker.length;
            VCJPEGParserReset(&_mjpegParserState);
            [self compactMJPEGReceiveBufferLockedIfNeeded:NO];
            [self reportMalformedMJPEGStream:@"MJPEG stream contained an invalid JPEG frame"];
            continue;
        }
        if (parserResult == VCJPEGParserResultNeedMoreData) {
            if (availableImageBytes > VCMaximumJPEGFrameBytes) {
                [self resetMJPEGReceiveBufferLocked];
                [self reportMalformedMJPEGStream:@"MJPEG frame exceeded its safety limit"];
            }
            break;
        }
        if (parsedImageLength > VCMaximumJPEGFrameBytes ||
            parsedImageLength > availableImageBytes) {
            [self resetMJPEGReceiveBufferLocked];
            [self reportMalformedMJPEGStream:@"MJPEG frame exceeded its safety limit"];
            continue;
        }
        NSUInteger imageLength = (NSUInteger)parsedImageLength;

        // A network callback can contain several complete frames after Wi-Fi
        // jitter or temporary decoder pressure. Keep only the newest complete
        // JPEG in this callback so recovery catches up instead of displaying a
        // stale backlog frame-by-frame.
        if (latestJPEGData) _mjpegSupersededFrameCount++;
        latestJPEGData = [imageData subdataWithRange:NSMakeRange(_mjpegBufferOffset,
                                                                 imageLength)];
        latestJPEGWidth = _mjpegParserState.sawFrameDimensions
            ? _mjpegParserState.width : 0;
        latestJPEGHeight = _mjpegParserState.sawFrameDimensions
            ? _mjpegParserState.height : 0;
        _mjpegParsedFrameCount++;
        _mjpegBufferOffset += imageLength;
        VCJPEGParserReset(&_mjpegParserState);
        [self compactMJPEGReceiveBufferLockedIfNeeded:NO];
    }

    if (latestJPEGData) {
        if (_pendingMJPEGData) _mjpegSupersededFrameCount++;
        _pendingMJPEGData = latestJPEGData;
        _pendingMJPEGWidth = latestJPEGWidth;
        _pendingMJPEGHeight = latestJPEGHeight;
        _pendingMJPEGConnectionGeneration = _mjpegConnectionGeneration;
        if (!_mjpegDecodeScheduled) {
            _mjpegDecodeScheduled = YES;
            dispatch_async(self.mjpegDecodeQueue, ^{ [self decodePendingMJPEGFrames]; });
        }
    }
    os_unfair_lock_unlock(&_mjpegReceiveLock);
}

- (void)decodePendingMJPEGFrames {
    while (YES) {
        NSData *jpegData = nil;
        size_t width = 0;
        size_t height = 0;
        NSUInteger connectionGeneration = 0;
        os_unfair_lock_lock(&_mjpegReceiveLock);
        jpegData = _pendingMJPEGData;
        width = _pendingMJPEGWidth;
        height = _pendingMJPEGHeight;
        connectionGeneration = _pendingMJPEGConnectionGeneration;
        _pendingMJPEGData = nil;
        _pendingMJPEGWidth = 0;
        _pendingMJPEGHeight = 0;
        if (!jpegData) {
            _mjpegDecodeScheduled = NO;
            os_unfair_lock_unlock(&_mjpegReceiveLock);
            return;
        }
        os_unfair_lock_unlock(&_mjpegReceiveLock);

        @autoreleasepool {
            CFTimeInterval decodeStartedAt = CACurrentMediaTime();
            BOOL usedVideoToolbox = NO;
            CVPixelBufferRef pixelBuffer = [self copyPixelBufferFromJPEGData:jpegData
                                                                        width:width
                                                                       height:height
                                                       usedVideoToolbox:&usedVideoToolbox];
            CFTimeInterval decodeSeconds = CACurrentMediaTime() - decodeStartedAt;
            BOOL reportStatistics = NO;
            uint64_t parsedFrames = 0;
            uint64_t decodedFrames = 0;
            uint64_t supersededFrames = 0;
            uint64_t vtFrames = 0;
            uint64_t fallbackFrames = 0;
            uint64_t failedFrames = 0;
            CFTimeInterval totalDecodeSeconds = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            os_unfair_lock_lock(&_mjpegReceiveLock);
            BOOL currentGeneration = connectionGeneration == _mjpegConnectionGeneration;
            if (currentGeneration) {
                _mjpegTotalDecodeSeconds += decodeSeconds;
                if (pixelBuffer) {
                    _mjpegDecodedFrameCount++;
                    if (usedVideoToolbox) {
                        _mjpegVTDecodedFrameCount++;
                    } else {
                        _mjpegFallbackDecodedFrameCount++;
                    }
                } else {
                    _mjpegDecodeFailureCount++;
                }
            }
            if (currentGeneration &&
                now - _mjpegLastStatisticsTime >= VCMJPEGStatisticsInterval) {
                _mjpegLastStatisticsTime = now;
                parsedFrames = _mjpegParsedFrameCount;
                decodedFrames = _mjpegDecodedFrameCount;
                supersededFrames = _mjpegSupersededFrameCount;
                vtFrames = _mjpegVTDecodedFrameCount;
                fallbackFrames = _mjpegFallbackDecodedFrameCount;
                failedFrames = _mjpegDecodeFailureCount;
                totalDecodeSeconds = _mjpegTotalDecodeSeconds;
                reportStatistics = parsedFrames > 0;
            }
            os_unfair_lock_unlock(&_mjpegReceiveLock);
            if (reportStatistics) {
                double averageDecodeMilliseconds = decodedFrames + failedFrames > 0
                    ? (totalDecodeSeconds * 1000.0) / (double)(decodedFrames + failedFrames)
                    : 0;
                NSLog(@"[VirtualCamPro] MJPEG health: parsed=%llu decoded=%llu "
                       "latest-dropped=%llu decode-failed=%llu vt=%llu imageio=%llu "
                       "average-decode=%.2fms",
                      (unsigned long long)parsedFrames,
                      (unsigned long long)decodedFrames,
                      (unsigned long long)supersededFrames,
                      (unsigned long long)failedFrames,
                      (unsigned long long)vtFrames,
                      (unsigned long long)fallbackFrames,
                      averageDecodeMilliseconds);
            }
            if (!pixelBuffer) {
                [self reportMalformedMJPEGStream:@"MJPEG JPEG decoding failed"];
                continue;
            }
            os_unfair_lock_lock(&_mjpegReceiveLock);
            BOOL current = connectionGeneration == _mjpegConnectionGeneration;
            os_unfair_lock_unlock(&_mjpegReceiveLock);
            if (current && self.running) [self deliverPixelBuffer:pixelBuffer];
            CVPixelBufferRelease(pixelBuffer);
        }
    }
}

- (void)reportMalformedMJPEGStream:(NSString *)description {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (self) {
        if (_lastMJPEGErrorReportTime > 0 &&
            now - _lastMJPEGErrorReportTime < 30.0) return;
        _lastMJPEGErrorReportTime = now;
    }
    NSError *error = [NSError errorWithDomain:VCStreamErrorDomain
                                     code:1006
                                 userInfo:@{NSLocalizedDescriptionKey: description}];
    [self reportError:error];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (session != self.session) {
        [session finishTasksAndInvalidate];
        return;
    }

    self.task = nil;
    self.session = nil;
    self.delegateQueue = nil;
    os_unfair_lock_lock(&_mjpegReceiveLock);
    self.imageData = nil;
    [self resetMJPEGReceiveBufferLocked];
    os_unfair_lock_unlock(&_mjpegReceiveLock);
    [session finishTasksAndInvalidate];

    if (!self.running) return;
    NSError *finalError = error ?: [NSError errorWithDomain:VCStreamErrorDomain
                                                            code:1003
                                                        userInfo:@{NSLocalizedDescriptionKey: @"MJPEG stream ended"}];
    [self scheduleReconnectAfterError:finalError];
}

- (void)dealloc {
    if (self.observingPlayerItem && self.hlsPlayerItem) {
        @try {
            [self.hlsPlayerItem removeObserver:self forKeyPath:@"status" context:VCPlayerItemStatusContext];
        } @catch (__unused NSException *exception) {
        }
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.frameTimer) dispatch_source_cancel(self.frameTimer);
    if (self.healthTimer) dispatch_source_cancel(self.healthTimer);
    [self.task cancel];
    [self.session invalidateAndCancel];
    [self releaseMJPEGDecompressionSession];
    [self releaseMJPEGPixelBufferPool];
}

@end
